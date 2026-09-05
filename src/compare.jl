# Diffing two API surfaces, and the semver arithmetic that turns a diff into a
# required version bump.

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
# Type-level "is this still accepted?" reasoning
# ---------------------------------------------------------------------------

"""
    type_covers(new::AbstractString, old::AbstractString) -> Bool

Conservatively decide whether an argument annotated `old` in the released
version is still accepted by a method annotating that position `new`.

We do not have real types here (nothing is loaded), so this recognises the
widenings that occur in practice — an identical annotation, a widening to `Any`,
and growing a `Union` — and reports anything else as a potential break.  Erring
towards "changed" is the right bias for a reminder tool: a false *major*
suggestion costs a glance at the report, a missed break costs a broken release.
"""
function type_covers(new::AbstractString, old::AbstractString)
    new == old && return true
    new == "Any" && return true
    old == "Any" && return false
    # Union{A,B} still accepts everything A accepted.
    if startswith(new, "Union{") && endswith(new, "}")
        return old in _union_members(new)
    end
    return false
end

function _union_members(s::AbstractString)
    ex = try
        Meta.parse(s)
    catch
        return String[]
    end
    (ex isa Expr && ex.head === :curly && ex.args[1] === :Union) || return String[]
    out = String[]
    for a in ex.args[2:end]
        m = string(a)
        push!(out, m)
        # Unions nest: Union{A, Union{B,C}}
        startswith(m, "Union{") && append!(out, _union_members(m))
    end
    return out
end

"""
    covers(new::ConcreteSig, old::ConcreteSig) -> Bool

Whether every call accepted by the released signature `old` is still accepted by
`new`.
"""
function covers(new::ConcreteSig, old::ConcreteSig)
    if new.vararg === nothing
        old.vararg === nothing || return false
        length(new.types) == length(old.types) || return false
        return all(type_covers(n, o) for (n, o) in zip(new.types, old.types))
    end
    # `new` ends in a vararg, so it can absorb any number of trailing arguments.
    length(old.types) >= length(new.types) || return false
    for i in eachindex(new.types)
        type_covers(new.types[i], old.types[i]) || return false
    end
    for i in (length(new.types) + 1):length(old.types)
        type_covers(new.vararg, old.types[i]) || return false
    end
    old.vararg === nothing || type_covers(new.vararg, old.vararg) || return false
    return true
end

covered_by_any(sigs, sig) = any(s -> covers(s, sig), sigs)

# ---------------------------------------------------------------------------
# Surface diffing
# ---------------------------------------------------------------------------

_loc(file, line) = isempty(file) ? "" : "$(file):$(line)"

function _kind_of(s::APISurface, name::Symbol)
    haskey(s.types, name) && return :type
    haskey(s.functions, name) && return :function
    haskey(s.macros, name) && return :macro
    haskey(s.consts, name) && return :const
    return :unknown
end

"""
    compare_surfaces(old::APISurface, new::APISurface) -> Vector{Change}

Diff two extracted surfaces.  Only names that are `export`ed or `public` in
either version are considered; internal churn is invisible by design.
"""
function compare_surfaces(old::APISurface, new::APISurface)
    changes = Change[]
    old_public = public_names(old)
    new_public = public_names(new)

    for name in sort!(collect(setdiff(old_public, new_public)); by=string)
        push!(changes, Change(Major, :export_removed, name,
                              "`$(name)` is no longer exported", ""))
    end
    for name in sort!(collect(setdiff(new_public, old_public)); by=string)
        push!(changes, Change(Minor, :export_added, name,
                              "`$(name)` is newly exported", _new_location(new, name)))
    end

    for name in sort!(collect(intersect(old_public, new_public)); by=string)
        _compare_name!(changes, old, new, name)
    end
    sort!(changes; rev=true)
    return changes
end

function _new_location(s::APISurface, name::Symbol)
    haskey(s.types, name) && return _loc(s.types[name].file, s.types[name].line)
    haskey(s.consts, name) && return _loc(s.consts[name].file, s.consts[name].line)
    for d in (s.functions, s.macros)
        if haskey(d, name) && !isempty(d[name])
            m = first(d[name])
            return _loc(m.file, m.line)
        end
    end
    return ""
end

function _compare_name!(changes, old, new, name)
    ok, nk = _kind_of(old, name), _kind_of(new, name)
    if ok !== nk && ok !== :unknown && nk !== :unknown
        push!(changes, Change(Major, :kind_changed, name,
                              "`$(name)` changed from a $(ok) to a $(nk)",
                              _new_location(new, name)))
        return
    end
    if ok !== :unknown && nk === :unknown
        push!(changes, Change(Major, :definition_removed, name,
                              "`$(name)` is exported but its $(ok) definition is gone", ""))
        return
    end

    if nk === :type
        _compare_type!(changes, old.types[name], new.types[name])
    elseif nk === :function
        _compare_function!(changes, name, get(old.functions, name, MethodSig[]),
                           new.functions[name])
    elseif nk === :macro
        _compare_function!(changes, name, get(old.macros, name, MethodSig[]),
                           new.macros[name])
    elseif nk === :const
        _compare_const!(changes, old.consts[name], new.consts[name])
    end
end

function _compare_type!(changes, o::TypeDef, n::TypeDef)
    loc = _loc(n.file, n.line)
    name = n.name
    if o.kind !== n.kind
        push!(changes, Change(Major, :type_kind_changed, name,
                              "`$(name)` changed from `$(o.kind)` to `$(n.kind)`", loc))
        return
    end
    if o.ismutable != n.ismutable
        push!(changes, Change(Major, :mutability_changed, name,
                              "`$(name)` became $(n.ismutable ? "mutable" : "immutable")", loc))
    end
    if o.supertype != n.supertype
        push!(changes, Change(Major, :supertype_changed, name,
                              "`$(name)` supertype changed: `$(o.supertype)` → `$(n.supertype)`", loc))
    end
    if length(o.params) != length(n.params)
        push!(changes, Change(Major, :type_params_changed, name,
                              "`$(name)` now takes $(length(n.params)) type parameter(s), was $(length(o.params))", loc))
    else
        for (i, (op, np)) in enumerate(zip(o.params, n.params))
            if op != np && !type_covers(np, op)
                push!(changes, Change(Major, :type_params_changed, name,
                                      "`$(name)` type parameter $(i) bound narrowed: `$(op)` → `$(np)`", loc))
            end
        end
    end
    o.kind === :struct || return

    ofields, nfields = o.fields, n.fields
    onames = [f[1] for f in ofields]
    nnames = [f[1] for f in nfields]
    for f in onames
        if !(f in nnames)
            push!(changes, Change(Major, :field_removed, name,
                                  "`$(name)` lost field `$(f)::$(ofields[findfirst(==(f), onames)][2])`", loc))
        end
    end
    for (i, f) in enumerate(nnames)
        if !(f in onames)
            # A new field changes the implicit constructor's arity and the
            # object's layout, so this is breaking even though it "only adds".
            push!(changes, Change(Major, :field_added, name,
                                  "`$(name)` gained field `$(f)::$(nfields[i][2])` (changes layout and the default constructor)", loc))
        end
    end
    if length(onames) == length(nnames) && onames != nnames && sort(string.(onames)) == sort(string.(nnames))
        push!(changes, Change(Major, :fields_reordered, name,
                              "`$(name)` fields reordered: $(join(onames, ", ")) → $(join(nnames, ", "))", loc))
    end
    for (i, of) in enumerate(ofields)
        j = findfirst(==(of[1]), nnames)
        j === nothing && continue
        nf = nfields[j]
        if of[2] != nf[2]
            push!(changes, Change(Major, :field_type_changed, name,
                                  "`$(name).$(of[1])` type changed: `$(of[2])` → `$(nf[2])`", loc))
        end
    end
end

function _compare_function!(changes, name, olds::Vector{MethodSig}, news::Vector{MethodSig})
    old_sigs = reduce(vcat, map(expand_arities, olds); init=ConcreteSig[])
    # Keep each expanded arity paired with the method it came from, so a new
    # method is reported at the line it is actually written on.
    new_pairs = [(sig, m) for m in news for sig in expand_arities(m)]
    new_sigs = ConcreteSig[p[1] for p in new_pairs]
    loc = isempty(news) ? "" : _loc(news[1].file, news[1].line)

    for os in old_sigs
        if !covered_by_any(new_sigs, os)
            push!(changes, Change(Major, :method_removed, name,
                                  "no method accepts `$(signature_string(name, os))` any more", loc))
        end
    end
    for (ns, m) in new_pairs
        if !covered_by_any(old_sigs, ns)
            push!(changes, Change(Minor, :method_added, name,
                                  "new method `$(signature_string(name, ns))`",
                                  _loc(m.file, m.line)))
        end
    end
    _compare_kwargs!(changes, name, olds, news, loc)
end

function _compare_kwargs!(changes, name, olds, news, loc)
    old_kw = Dict(k.name => k for m in olds for k in m.kwargs)
    new_kw = Dict(k.name => k for m in news for k in m.kwargs)
    new_slurps = any(k.is_slurp for m in news for k in m.kwargs)

    for (kn, k) in sort!(collect(old_kw); by=first)
        k.is_slurp && continue
        if !haskey(new_kw, kn) && !new_slurps
            push!(changes, Change(Major, :kwarg_removed, name,
                                  "keyword argument `$(kn)` of `$(name)` was removed", loc))
        end
    end
    for (kn, k) in sort!(collect(new_kw); by=first)
        k.is_slurp && continue
        if !haskey(old_kw, kn)
            level = k.has_default ? Minor : Major
            detail = k.has_default ?
                "new keyword argument `$(kn)` on `$(name)`" :
                "`$(name)` now requires keyword argument `$(kn)`, which did not exist before"
            push!(changes, Change(level, :kwarg_added, name, detail, loc))
        elseif !k.has_default && old_kw[kn].has_default
            push!(changes, Change(Major, :kwarg_required, name,
                                  "keyword argument `$(kn)` of `$(name)` is now required", loc))
        end
    end
end

function _compare_const!(changes, o::ConstDef, n::ConstDef)
    if o.type != n.type && !isempty(o.type) && !isempty(n.type)
        push!(changes, Change(Major, :const_type_changed, n.name,
                              "`$(n.name)` declared type changed: `$(o.type)` → `$(n.type)`",
                              _loc(n.file, n.line)))
    end
end

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
