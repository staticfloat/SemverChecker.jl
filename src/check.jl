# Discovering the packages in a repository, driving the two analysis
# subprocesses, and assembling the verdicts.

const DEFAULT_SKIP = Set([".git", ".github", "docs", "test", "benchmark",
                          "perf", "node_modules", ".julia"])

const WORKER = joinpath(@__DIR__, "worker.jl")

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
        _is_package(dir) && push!(found, dir)
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
    notes::Vector{String}
end


# ---------------------------------------------------------------------------
# Driving the worker
# ---------------------------------------------------------------------------

"""
    run_worker(request::Dict; log=nothing) -> Dict

Run `worker.jl` in a fresh Julia process and return its response.

A subprocess is not an implementation detail here, it is the design: the two
versions of a package cannot coexist in one session, and loading them into
*this* process would perturb the checker's own dependency resolution.  Packages
also print during `__init__`, so the child's output is captured rather than
interleaved with the report.
"""
function run_worker(request::Dict; log::Union{Nothing,String}=nothing)
    reqfile, respfile = tempname(), tempname()
    Serialization.serialize(reqfile, request)
    script = "include($(repr(WORKER))); exit(Main.SemverWorker.main())"
    cmd = `$(Base.julia_cmd()) --startup-file=no --color=no -e $script $reqfile $respfile`
    logfile = log === nothing ? tempname() : log
    try
        open(logfile, "w") do io
            run(pipeline(cmd; stdout=io, stderr=io))
        end
    catch e
        out = isfile(logfile) ? read(logfile, String) : ""
        return Dict{String,Any}("__fatal__" =>
            "worker process failed: $(sprint(showerror, e))\n$(last(out, 2000))")
    finally
        rm(reqfile; force=true)
    end
    isfile(respfile) || return Dict{String,Any}("__fatal__" => "worker produced no output")
    resp = try
        Serialization.deserialize(respfile)
    catch e
        Dict{String,Any}("__fatal__" => "unreadable worker output: $(sprint(showerror, e))")
    finally
        rm(respfile; force=true)
    end
    return resp
end

# ---------------------------------------------------------------------------
# The check
# ---------------------------------------------------------------------------

struct _Pkg
    name::String
    uuid::Base.UUID
    version::Union{Nothing,VersionNumber}
    dir::String
    relpath::String
end

"""
    check(root="."; kwargs...) -> Vector{PackageReport}

Scan the repository at `root` and report, for every package it contains,
whether the version in `Project.toml` has been bumped enough to cover the
changes made since the latest registered release.

Both the released versions and the working tree are *loaded* — in two
subprocesses, batched so that a monorepo costs two loads in total — and their
surfaces are compared using real Julia dispatch. This sees reexported names,
methods produced by code generation, and resolved type aliases, none of which
are visible in the source text.

# Keyword arguments
  - `packages`: explicit list of package directories, bypassing discovery.
  - `skip`: directory names not to descend into during discovery.
  - `allow_prerelease`: treat `1.2.0-DEV` as satisfying a bump to `1.2.0`
    (default `true`, matching common Julia practice).
  - `registries`: registries to search (defaults to all reachable ones).
  - `logdir`: where to keep the subprocess logs (default: a temporary directory).
"""
function check(root::AbstractString="."; packages=nothing, skip=DEFAULT_SKIP,
               allow_prerelease::Bool=true,
               registries=Pkg.Registry.reachable_registries(),
               logdir::Union{Nothing,String}=nothing)
    root = abspath(root)
    dirs = packages === nothing ? discover_packages(root; skip) :
           [abspath(joinpath(root, p)) for p in packages]
    logdir = logdir === nothing ? mktempdir() : (mkpath(logdir); logdir)

    pkgs = _Pkg[]
    reports = PackageReport[]
    for d in dirs
        proj = try
            TOML.parsefile(joinpath(d, "Project.toml"))
        catch e
            push!(reports, _bare(basename(d), relpath(d, root), :error,
                                 "unreadable Project.toml: $(sprint(showerror, e))"))
            continue
        end
        name = get(proj, "name", basename(d))
        rel = relpath(d, root)
        if !haskey(proj, "version")
            push!(reports, _bare(name, rel, :no_version, "Project.toml has no `version` field"))
            continue
        end
        push!(pkgs, _Pkg(name, Base.UUID(proj["uuid"]),
                         VersionNumber(proj["version"]), d, rel))
    end
    isempty(pkgs) && return reports

    # Which packages have a release to compare against?
    registered = Dict{String,RegisteredVersion}()
    for p in pkgs
        rv = latest_registered(p.name; uuid=p.uuid, registries)
        rv === nothing || (registered[p.name] = rv)
    end

    old = Dict{String,Any}()
    if !isempty(registered)
        resp = run_worker(Dict{String,Any}(
                "mode" => "dump",
                "specs" => [Dict{String,Any}("name" => n, "version" => string(rv.version))
                            for (n, rv) in sort(collect(registered); by=first)]);
            log = joinpath(logdir, "released.log"))
        if haskey(resp, "__fatal__")
            for p in pkgs
                push!(reports, _bare(p.name, p.relpath, :error,
                                     "could not analyze released versions: $(resp["__fatal__"])",
                                     p.version, get(registered, p.name, nothing)))
            end
            return reports
        end
        old = resp
    end

    resp = run_worker(Dict{String,Any}(
            "mode" => "compare",
            "specs" => [Dict{String,Any}("name" => p.name, "path" => p.dir) for p in pkgs],
            "old" => Dict{String,Any}(k => v for (k, v) in old if !haskey(v, "error")));
        log = joinpath(logdir, "working-tree.log"))
    if haskey(resp, "__fatal__")
        for p in pkgs
            push!(reports, _bare(p.name, p.relpath, :error,
                                 "could not analyze the working tree: $(resp["__fatal__"])",
                                 p.version, get(registered, p.name, nothing)))
        end
        return reports
    end

    for p in pkgs
        push!(reports, _assemble(p, get(registered, p.name, nothing),
                                 get(old, p.name, nothing), get(resp, p.name, nothing),
                                 allow_prerelease))
    end
    sort!(reports; by = r -> r.name)
    return reports
end

_bare(name, path, status, msg, ver=nothing, rv=nothing) =
    PackageReport(name, path, ver, rv, NoChange, Change[], nothing, status, msg, String[])

function _assemble(p::_Pkg, rv, oldsurf, newsurf, allow_prerelease)
    notes = String[]
    if newsurf === nothing
        return _bare(p.name, p.relpath, :error,
                     "the working tree was not analyzed", p.version, rv)
    end
    if haskey(newsurf, "error")
        return _bare(p.name, p.relpath, :error,
                     "working tree: $(newsurf["error"])", p.version, rv)
    end
    if rv === nothing
        return _bare(p.name, p.relpath, :unregistered,
                     "not found in any reachable registry; nothing to compare against",
                     p.version, nothing)
    end
    if oldsurf === nothing || haskey(oldsurf, "error")
        why = oldsurf === nothing ? "not analyzed" : oldsurf["error"]
        return _bare(p.name, p.relpath, :error,
                     "released v$(rv.version): $(why)", p.version, rv)
    end

    changes = Change[Change(d) for d in get(newsurf, "changes", Any[])]
    touched = get(oldsurf, "source_hash", "") != get(newsurf, "source_hash", "!")
    level = overall_level(changes, touched)
    minimum_version = bump_version(rv.version, level)
    ok = is_sufficient(rv.version, p.version, level; allow_prerelease)

    sort!(changes; rev=true)
    return PackageReport(p.name, p.relpath, p.version, rv, level, changes,
                         minimum_version, ok ? :ok : :needs_bump, "", notes)
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
