# The verdict vocabulary — a change and how severe it is — and the semver
# arithmetic that turns a set of changes into a required version bump.
#
# The changes themselves are produced by `SemverWorker.compare` in a subprocess
# where the package is loaded; this file only interprets them.

"""
    BumpLevel

How much of a version bump a set of changes requires.  Ordered, so `max` over a
set of changes gives the overall requirement.
"""
@enum BumpLevel NoChange = 0 Patch = 1 Minor = 2 Major = 3

"""
    Change

One difference between the registered API surface and the working-tree surface.
"""
struct Change
    level::BumpLevel
    kind::Symbol
    name::Symbol
    detail::String
    location::String        # "src/foo.jl:12" in the working tree, "" if unknown
end

Base.isless(a::Change, b::Change) = (a.level, string(a.name)) < (b.level, string(b.name))

# ---------------------------------------------------------------------------
# Semver arithmetic (Pkg flavour)
# ---------------------------------------------------------------------------

"""
    bump_version(v::VersionNumber, level::BumpLevel) -> VersionNumber

The smallest version that constitutes a `level` bump over `v`, following the
convention Pkg's resolver actually enforces: below `1.0.0` the leading non-zero
component behaves as the major component, so a breaking change to `0.4.2` is
`0.5.0` and a feature addition is `0.4.3`.
"""
function bump_version(v::VersionNumber, level::BumpLevel)
    level == NoChange && return v
    if v.major > 0
        level == Major && return VersionNumber(v.major + 1, 0, 0)
        level == Minor && return VersionNumber(v.major, v.minor + 1, 0)
        return VersionNumber(v.major, v.minor, v.patch + 1)
    elseif v.minor > 0
        # 0.x.y — `x` is the breaking component; features and fixes share `y`.
        level == Major && return VersionNumber(0, v.minor + 1, 0)
        return VersionNumber(0, v.minor, v.patch + 1)
    else
        # 0.0.z — everything is potentially breaking.
        return VersionNumber(0, 0, v.patch + 1)
    end
end

"""
    is_sufficient(registered, current, level; allow_prerelease=true) -> Bool

Whether `current` is already bumped far enough past `registered` for a change of
severity `level`.

With `allow_prerelease` (the default) a prerelease tag is ignored when comparing,
so the common `version = "1.3.0-DEV"` development marker counts as `1.3.0`.
"""
function is_sufficient(registered::VersionNumber, current::VersionNumber,
                       level::BumpLevel; allow_prerelease::Bool=true)
    level == NoChange && return current >= registered
    cur = allow_prerelease ? _strip_prerelease(current) : current
    return cur >= bump_version(registered, level)
end

_strip_prerelease(v::VersionNumber) = VersionNumber(v.major, v.minor, v.patch)

"""
    overall_level(changes, changed::Bool) -> BumpLevel

Reduce a change list to a single requirement.  `changed` says whether the source
tree differs from the released one at all: when nothing changed, no bump is
needed; when only internals changed, a patch release is the right thing.
"""
function overall_level(changes::Vector{Change}, changed::Bool)
    isempty(changes) && return changed ? Patch : NoChange
    return maximum(c.level for c in changes)
end

"""
    Change(d::AbstractDict)

Rebuild a [`Change`](@ref) from the plain-data form the worker subprocess
returns.
"""
function Change(d::AbstractDict)
    lvl = d["level"] == "major" ? Major : d["level"] == "minor" ? Minor : Patch
    return Change(lvl, Symbol(d["kind"]), Symbol(d["name"]),
                  String(d["detail"]), String(get(d, "location", "")))
end
