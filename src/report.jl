# Rendering reports: for a terminal, for a GitHub Actions log, for a job
# summary, and for machines.

const LEVEL_NAME = Dict(NoChange => "none", Patch => "patch", Minor => "minor", Major => "major")

_level_name(l::BumpLevel) = LEVEL_NAME[l]

"""
    version_line(project_toml) -> Int

Line number of the `version = "..."` entry, so annotations point at the line the
developer needs to edit.  Falls back to line 1.
"""
function version_line(project_toml::AbstractString)
    isfile(project_toml) || return 1
    for (i, line) in enumerate(eachline(project_toml))
        occursin(r"^\s*version\s*=", line) && return i
    end
    return 1
end

"""
    summary_line(r::PackageReport) -> String

The one-line verdict for a package.
"""
function summary_line(r::PackageReport)
    if r.status === :needs_bump
        return "$(r.name): bump version to at least $(r.minimum_version) " *
               "(currently $(r.current_version), released $(r.registered.version), " *
               "detected $(_level_name(r.level)) change)"
    elseif r.status === :ok
        reg = r.registered === nothing ? "unreleased" : "v$(r.registered.version)"
        if r.level == NoChange
            return "$(r.name): unchanged since $(reg)"
        end
        return "$(r.name): v$(r.current_version) already covers the " *
               "$(_level_name(r.level)) change since $(reg)"
    elseif r.status === :unregistered
        return "$(r.name): $(r.message)"
    elseif r.status === :no_version
        return "$(r.name): $(r.message)"
    end
    return "$(r.name): $(r.message)"
end

# ---------------------------------------------------------------------------
# Terminal
# ---------------------------------------------------------------------------

const _STATUS_COLOR = Dict(:needs_bump => :red, :ok => :green, :unregistered => :cyan,
                           :no_version => :yellow, :error => :yellow)
const _STATUS_MARK = Dict(:needs_bump => "✗", :ok => "✓", :unregistered => "·",
                          :no_version => "!", :error => "!")

"""
    print_report(io, reports; verbose=false, color=…)

Human-readable report.  Packages needing a bump list the changes that drove the
verdict; everything else gets a single line unless `verbose`.
"""
function print_report(io::IO, reports::Vector{PackageReport}; verbose::Bool=false,
                      color::Bool=get(io, :color, false), max_changes::Int=12)
    _c(s, c) = color ? sprint((o, x) -> printstyled(o, x; color=c, bold=(c === :red)), s; context=io) : s
    for r in reports
        r.status === :ok && !verbose && r.level == NoChange && isempty(r.notes) && continue
        mark = _STATUS_MARK[r.status]
        col = _STATUS_COLOR[r.status]
        println(io, _c("$(mark) ", col), summary_line(r))
        if r.status === :needs_bump || (verbose && !isempty(r.changes))
            shown = r.changes[1:min(end, max_changes)]
            for c in shown
                loc = isempty(c.location) ? "" : "  ($(normpath(joinpath(r.path, c.location))))"
                println(io, "    ", _c("[$(_level_name(c.level))]", c.level == Major ? :red : :yellow),
                        " ", c.detail, loc)
            end
            if length(r.changes) > length(shown)
                println(io, "    … and $(length(r.changes) - length(shown)) more change(s)")
            end
        end
        for e in r.notes
            println(io, "    ", _c("[note]", :yellow), " ", e)
        end
    end
    n_bad = count(r -> r.status === :needs_bump, reports)
    println(io)
    if n_bad == 0
        println(io, _c("All $(length(reports)) package(s) have an acceptable version.", :green))
    else
        println(io, _c("$(n_bad) of $(length(reports)) package(s) need a version bump.", :red))
    end
    return n_bad
end

# ---------------------------------------------------------------------------
# GitHub Actions
# ---------------------------------------------------------------------------

_gha_escape(s) = replace(s, "%" => "%25", "\r" => "%0D", "\n" => "%0A")

"""
    print_github_annotations(io, reports; root=".")

Emit GitHub Actions workflow commands.  Each package needing a bump produces an
`::error` annotation attached to the `version` line of its `Project.toml`, so the
message shows up inline on the pull request diff.
"""
function print_github_annotations(io::IO, reports::Vector{PackageReport}; root::AbstractString=".")
    for r in reports
        file = normpath(joinpath(r.path, "Project.toml"))
        line = version_line(joinpath(abspath(root), file))
        if r.status === :needs_bump
            body = "$(r.name) has $(_level_name(r.level)) changes since v$(r.registered.version) " *
                   "but Project.toml still says $(r.current_version).\n" *
                   "Set version = \"$(r.minimum_version)\" (or higher)."
            if !isempty(r.changes)
                body *= "\n\n" * join(["• " * c.detail for c in r.changes[1:min(end, 10)]], "\n")
            end
            println(io, "::error file=$(file),line=$(line),title=Version bump needed::$(_gha_escape(body))")
        elseif r.status === :error
            println(io, "::warning file=$(file),line=$(line),title=SemverChecker::$(_gha_escape(r.message))")
        end
        for note in r.notes
            println(io, "::notice file=$(file),line=$(line),title=SemverChecker::$(_gha_escape(note))")
        end
    end
end

# ---------------------------------------------------------------------------
# Markdown (job summary / PR comment)
# ---------------------------------------------------------------------------

"""
    print_markdown(io, reports)

A Markdown report suitable for `\$GITHUB_STEP_SUMMARY` or a PR comment.
"""
function print_markdown(io::IO, reports::Vector{PackageReport})
    n_bad = count(r -> r.status === :needs_bump, reports)
    println(io, "## Version bump check\n")
    if n_bad == 0
        println(io, "All $(length(reports)) package(s) have an acceptable version. ✅\n")
    else
        println(io, "$(n_bad) of $(length(reports)) package(s) need a version bump. ❌\n")
    end
    println(io, "| Package | Registered | Project.toml | Detected change | Required |")
    println(io, "|---|---|---|---|---|")
    for r in reports
        reg = r.registered === nothing ? "—" : string(r.registered.version)
        cur = r.current_version === nothing ? "—" : string(r.current_version)
        req = if r.status === :needs_bump
            "**≥ $(r.minimum_version)** ❌"
        elseif r.status === :ok
            "ok ✅"
        else
            String(r.status)
        end
        println(io, "| `$(r.name)` | $(reg) | $(cur) | $(_level_name(r.level)) | $(req) |")
    end
    println(io)
    for r in reports
        (r.status === :needs_bump && !isempty(r.changes)) || continue
        println(io, "<details><summary>Why <code>$(r.name)</code> needs a " *
                    "$(_level_name(r.level)) bump</summary>\n")
        for c in r.changes
            loc = isempty(c.location) ? "" : " — `$(normpath(joinpath(r.path, c.location)))`"
            println(io, "- **$(_level_name(c.level))**: $(c.detail)$(loc)")
        end
        println(io, "\n</details>\n")
    end
    for r in reports
        r.status === :error || continue
        println(io, "> ⚠️ `$(r.name)`: $(r.message)")
    end
end

# ---------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------

_json(s::AbstractString) = string('"', replace(s, '\\' => "\\\\", '"' => "\\\"",
                                               '\n' => "\\n", '\r' => "\\r", '\t' => "\\t"), '"')
_json(x::Nothing) = "null"
_json(x::Bool) = string(x)
_json(x::Integer) = string(x)
_json(x::Union{VersionNumber,Symbol}) = _json(string(x))
_json(xs::AbstractVector) = string("[", join(map(_json, xs), ","), "]")
_json(p::Pair) = string(_json(string(p.first)), ":", _json(p.second))
_json(d::AbstractVector{<:Pair}) = string("{", join(map(_json, d), ","), "}")

function _json(c::Change)
    _json([
        "level" => _level_name(c.level), "kind" => c.kind, "name" => string(c.name),
        "detail" => c.detail, "location" => c.location,
    ])
end

function _json(r::PackageReport)
    _json([
        "name" => r.name,
        "path" => r.path,
        "status" => r.status,
        "current_version" => r.current_version,
        "registered_version" => r.registered === nothing ? nothing : r.registered.version,
        "level" => _level_name(r.level),
        "minimum_version" => r.minimum_version,
        "message" => r.message,
        "changes" => r.changes,
        "notes" => r.notes,
    ])
end

"""
    print_json(io, reports)

Machine-readable output, for scripting further CI behaviour.
"""
function print_json(io::IO, reports::Vector{PackageReport})
    println(io, _json([
        "ok" => count(r -> r.status === :needs_bump, reports) == 0,
        "packages" => reports,
    ]))
end
