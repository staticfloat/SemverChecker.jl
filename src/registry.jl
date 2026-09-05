# Locating the latest registered version of a package, and getting hold of its
# source tree so we can extract the released API surface.

"""
    RegisteredVersion

The newest non-yanked release of a package found in the reachable registries.
"""
struct RegisteredVersion
    name::String
    uuid::Base.UUID
    version::VersionNumber
    tree_hash::String
    registry::String
    repo::Union{Nothing,String}
    subdir::Union{Nothing,String}
end

"""
    latest_registered(name; uuid=nothing, registries=Pkg.Registry.reachable_registries())

Return the [`RegisteredVersion`](@ref) with the highest version number across all
reachable registries, or `nothing` when the package is not registered.

Yanked versions are ignored.  When `uuid` is given it must match, which keeps us
honest in the presence of name collisions between registries.
"""
function latest_registered(name::AbstractString;
                           uuid::Union{Nothing,Base.UUID}=nothing,
                           registries=Pkg.Registry.reachable_registries())
    best::Union{Nothing,RegisteredVersion} = nothing
    for reg in registries
        for (u, entry) in reg.pkgs
            entry.name == name || continue
            uuid === nothing || u == uuid || continue
            info = try
                Pkg.Registry.registry_info(entry)
            catch e
                @warn "could not read registry info" package=name registry=reg.name exception=e
                continue
            end
            for (v, vinfo) in info.version_info
                vinfo.yanked && continue
                if best === nothing || v > best.version
                    best = RegisteredVersion(name, u, v,
                                             bytes2hex(vinfo.git_tree_sha1.bytes),
                                             reg.name, info.repo, info.subdir)
                end
            end
        end
    end
    return best
end

"""
    source_path(rv::RegisteredVersion; cache=nothing) -> String

Return a directory containing the source of the registered version `rv`.

Three strategies are tried in order, cheapest first:

1. the package is already installed in a depot at the matching tree hash;
2. download the source tarball from the configured package server;
3. clone `rv.repo` and extract the tree object directly with `git archive`.

The returned path may be inside a depot (do not modify it) or inside `cache`.
"""
function source_path(rv::RegisteredVersion; cache::Union{Nothing,String}=nothing)
    slug = Base.version_slug(rv.uuid, Base.SHA1(rv.tree_hash))
    for depot in DEPOT_PATH
        p = joinpath(depot, "packages", rv.name, slug)
        isdir(p) && isfile(joinpath(p, "Project.toml")) && return p
    end

    cache = cache === nothing ? mktempdir() : cache
    dest = joinpath(cache, "$(rv.name)-$(rv.tree_hash[1:12])")
    isdir(dest) && isfile(joinpath(dest, "Project.toml")) && return dest

    err_server = try
        return _download_from_server(rv, dest)
    catch e
        sprint(showerror, e)
    end
    err_git = try
        return _extract_via_git(rv, dest)
    catch e
        sprint(showerror, e)
    end
    error("""
          could not obtain source for $(rv.name) v$(rv.version) (tree $(rv.tree_hash)):
            package server: $(err_server)
            git fallback:   $(err_git)
          """)
end

function _download_from_server(rv::RegisteredVersion, dest::String)
    server = Pkg.pkg_server()
    server === nothing && error("no package server configured")
    url = "$(server)/package/$(rv.uuid)/$(rv.tree_hash)"
    tarball = tempname()
    try
        Downloads.download(url, tarball)
        mkpath(dest)
        open(GzipDecompressorStream, tarball) do io
            Tar.extract(io, dest; set_permissions=false)
        end
    finally
        rm(tarball; force=true)
    end
    return dest
end

function _extract_via_git(rv::RegisteredVersion, dest::String)
    rv.repo === nothing && error("registry entry has no repo URL")
    mktempdir() do tmp
        bare = joinpath(tmp, "repo.git")
        run(pipeline(`git clone --quiet --bare --filter=blob:none $(rv.repo) $(bare)`,
                     stdout=devnull, stderr=devnull))
        mkpath(dest)
        # The registered tree hash names the package subdirectory's tree object
        # directly, so we can extract it without knowing which commit it is on.
        run(pipeline(`git --git-dir=$(bare) archive --format=tar $(rv.tree_hash)`,
                     `tar -x -C $(dest)`))
    end
    return dest
end

"""
    registered_surface(rv::RegisteredVersion; cache=nothing) -> APISurface

Fetch and statically analyze the released source of `rv`.
"""
function registered_surface(rv::RegisteredVersion; cache::Union{Nothing,String}=nothing)
    return extract_surface(source_path(rv; cache))
end
