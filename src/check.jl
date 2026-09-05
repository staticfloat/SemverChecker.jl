# Discovering the packages in a repository and running the whole check.

const DEFAULT_SKIP = Set([".git", ".github", "docs", "test", "benchmark",
                          "perf", "node_modules", ".julia"])

"""
    discover_packages(root; skip=DEFAULT_SKIP) -> Vector{String}

Find every Julia package under `root`: a directory holding a `Project.toml` with
both a `name` and a `uuid`, plus a matching `src/<name>.jl` entry point.  This
deliberately ignores `test/` and `docs/` environments, which are projects but
not packages.

Nested packages are supported, so a monorepo laying its packages out as
`Foo.jl/`, `Bar.jl/` subdirectories is found in one pass.
"""
function discover_packages(root::AbstractString; skip=DEFAULT_SKIP)
    root = abspath(root)
    found = String[]
    function visit(dir, depth)
        depth > 8 && return
        if _is_package(dir)
            push!(found, dir)
            # A package's own subdirectories are its implementation, except that
            # monorepos sometimes nest packages further; keep descending but
            # never into src/.
        end
        for entry in sort(readdir(dir))
            entry in skip && continue
            startswith(entry, ".") && continue
            entry == "src" && continue
            p = joinpath(dir, entry)
            (isdir(p) && !islink(p)) && visit(p, depth + 1)
        end
    end
    visit(root, 0)
    return found
end

function _is_package(dir::AbstractString)
    proj_path = joinpath(dir, "Project.toml")
    isfile(proj_path) || return false
    proj = try
        TOML.parsefile(proj_path)
    catch
        return false
    end
    haskey(proj, "name") && haskey(proj, "uuid") || return false
    return isfile(joinpath(dir, "src", "$(proj["name"]).jl"))
end

"""
    PackageReport

The verdict for a single package.  `status` is one of

  - `:ok` — the version in `Project.toml` is already bumped far enough;
  - `:needs_bump` — the developer should raise the version;
  - `:unregistered` — no registered version to compare against;
  - `:no_version` — `Project.toml` has no `version` field;
  - `:error` — the comparison could not be made (reason in `message`).
"""
struct PackageReport
    name::String
    path::String                                  # relative to the scan root
    current_version::Union{Nothing,VersionNumber}
    registered::Union{Nothing,RegisteredVersion}
    level::BumpLevel
    changes::Vector{Change}
    minimum_version::Union{Nothing,VersionNumber}
    status::Symbol
    message::String
    parse_errors::Vector{String}
end

isok(r::PackageReport) = r.status !== :needs_bump

"""
    check(root="."; kwargs...) -> Vector{PackageReport}

Scan the repository at `root` and report, for every package it contains,
whether the version in `Project.toml` has been bumped enough to cover the
changes made since the latest registered release.

# Keyword arguments
  - `packages`: explicit list of package directories, bypassing discovery.
  - `skip`: directory names not to descend into during discovery.
  - `allow_prerelease`: treat `1.2.0-DEV` as satisfying a bump to `1.2.0`
    (default `true`, matching common Julia practice).
  - `cache`: directory in which to unpack downloaded release sources.
  - `registries`: registries to search (defaults to all reachable ones).
"""
function check(root::AbstractString="."; packages=nothing, skip=DEFAULT_SKIP,
               allow_prerelease::Bool=true, cache::Union{Nothing,String}=nothing,
               registries=Pkg.Registry.reachable_registries())
    root = abspath(root)
    # Explicit package paths are resolved against `root`, so `--package=.` means
    # "the package at the scan root" no matter what the working directory is.
    # An absolute path passed here still wins, as `joinpath` discards `root`.
    dirs = packages === nothing ? discover_packages(root; skip) :
           [abspath(joinpath(root, p)) for p in packages]
    cache = cache === nothing ? mktempdir() : cache
    return [check_package(d; root, allow_prerelease, cache, registries) for d in dirs]
end

"""
    check_package(pkgdir; root=pkgdir, kwargs...) -> PackageReport

Run the check for a single package directory.
"""
function check_package(pkgdir::AbstractString; root::AbstractString=pkgdir,
                       allow_prerelease::Bool=true,
                       cache::Union{Nothing,String}=nothing,
                       registries=Pkg.Registry.reachable_registries())
    pkgdir = abspath(pkgdir)
    # Kept as "." for a package that *is* the scan root, so that paths built
    # from it stay repo-relative (GitHub annotations need that).
    relative = relpath(pkgdir, abspath(root))

    local current::APISurface
    try
        current = extract_surface(pkgdir)
    catch e
        return PackageReport(basename(pkgdir), relative, nothing, nothing, NoChange,
                             Change[], nothing, :error,
                             "could not analyze working tree: $(sprint(showerror, e))", String[])
    end

    if current.version === nothing
        return PackageReport(current.name, relative, nothing, nothing, NoChange,
                             Change[], nothing, :no_version,
                             "Project.toml has no `version` field", current.parse_errors)
    end

    rv = latest_registered(current.name; uuid=current.uuid, registries)
    if rv === nothing
        return PackageReport(current.name, relative, current.version, nothing, NoChange,
                             Change[], nothing, :unregistered,
                             "not found in any reachable registry; nothing to compare against",
                             current.parse_errors)
    end

    local released::APISurface
    try
        released = registered_surface(rv; cache)
    catch e
        return PackageReport(current.name, relative, current.version, rv, NoChange,
                             Change[], nothing, :error,
                             "could not fetch v$(rv.version): $(sprint(showerror, e))",
                             current.parse_errors)
    end

    changes = compare_surfaces(released, current)
    touched = released.source_hash != current.source_hash
    level = overall_level(changes, touched)
    minimum_version = bump_version(rv.version, level)
    ok = is_sufficient(rv.version, current.version, level; allow_prerelease)

    # Both surfaces usually hit the same metaprogramming, so report each note once.
    errs = unique(vcat(current.parse_errors, released.parse_errors))
    return PackageReport(current.name, relative, current.version, rv, level, changes,
                         minimum_version, ok ? :ok : :needs_bump, "", errs)
end

"""
    apply_bumps!(reports; root=".") -> Vector{String}

Rewrite the `version` field of every `Project.toml` whose package needs a bump,
setting it to the minimum acceptable version.  Returns the paths that changed.

Intended for local use (`--fix`), not for CI: the point of the CI check is to
make the developer make this decision deliberately.
"""
function apply_bumps!(reports::Vector{PackageReport}; root::AbstractString=".")
    changed = String[]
    for r in reports
        r.status === :needs_bump || continue
        r.minimum_version === nothing && continue
        path = joinpath(abspath(root), r.path, "Project.toml")
        isfile(path) || continue
        src = read(path, String)
        new = replace(src,
                      r"(?m)^version\s*=\s*\"[^\"]*\"" => "version = \"$(r.minimum_version)\"";
                      count=1)
        if new != src
            write(path, new)
            push!(changed, path)
        end
    end
    return changed
end
