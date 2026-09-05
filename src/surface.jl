# Data model describing the *public API surface* of a package, as recovered by
# static analysis of its source.  Everything here is intentionally string-based:
# we never load the package, so types are compared by their normalized textual
# form rather than by `<:`.

"""
    ArgSpec

A single positional argument of a method signature.
"""
struct ArgSpec
    type::String        # normalized type expression; "Any" when unannotated
    has_default::Bool
    is_vararg::Bool
end

"""
    KwSpec

A single keyword argument of a method signature.  `is_slurp` marks `kwargs...`.
"""
struct KwSpec
    name::Symbol
    type::String
    has_default::Bool
    is_slurp::Bool
end

"""
    MethodSig

One method definition of a function or macro.
"""
struct MethodSig
    args::Vector{ArgSpec}
    kwargs::Vector{KwSpec}
    file::String
    line::Int
end

"""
    ConcreteSig

A single callable arity derived from a [`MethodSig`](@ref).  A method with
default arguments expands into several `ConcreteSig`s, mirroring the several
methods Julia actually defines for it.  `vararg` holds the element type of a
trailing `xs...` when present.
"""
struct ConcreteSig
    types::Vector{String}
    vararg::Union{Nothing,String}
end

"""
    TypeDef

A `struct`, `abstract type` or `primitive type` definition.
"""
struct TypeDef
    name::Symbol
    kind::Symbol                        # :struct | :abstract | :primitive
    ismutable::Bool
    params::Vector{String}
    supertype::String                   # "Any" when unspecified
    fields::Vector{Tuple{Symbol,String}}
    file::String
    line::Int
end

"""
    ConstDef

A `const` binding.  `type` is the declared type when one is given (`const x::T =
...`), otherwise a best-effort literal type or `""` when unknown.
"""
struct ConstDef
    name::Symbol
    type::String
    file::String
    line::Int
end

"""
    APISurface

The complete extracted surface of one package.  `exports` holds names made
available by `export`, `publics` those declared with `public` (Julia 1.11+).
Definitions are recorded for the whole package; only those whose name appears in
`exports`/`publics` participate in the semver comparison.
"""
struct APISurface
    name::String
    uuid::Union{Nothing,Base.UUID}
    version::Union{Nothing,VersionNumber}
    exports::Set{Symbol}
    publics::Set{Symbol}
    functions::Dict{Symbol,Vector{MethodSig}}
    macros::Dict{Symbol,Vector{MethodSig}}
    types::Dict{Symbol,TypeDef}
    consts::Dict{Symbol,ConstDef}
    source_hash::String
    parse_errors::Vector{String}
end

APISurface(name::AbstractString) = APISurface(
    name, nothing, nothing, Set{Symbol}(), Set{Symbol}(),
    Dict{Symbol,Vector{MethodSig}}(), Dict{Symbol,Vector{MethodSig}}(),
    Dict{Symbol,TypeDef}(), Dict{Symbol,ConstDef}(), "", String[],
)

"""
    public_names(s::APISurface) -> Set{Symbol}

Every name that forms part of the package's advertised API: `export`ed names
plus those marked `public`.
"""
public_names(s::APISurface) = union(s.exports, s.publics)

"""
    expand_arities(m::MethodSig) -> Vector{ConcreteSig}

Expand a method with optional positional arguments into the set of concrete
arities it actually defines.  `f(a, b=1, c=2)` yields three `ConcreteSig`s.
"""
function expand_arities(m::MethodSig)
    fixed = ArgSpec[]
    vararg = nothing
    for a in m.args
        if a.is_vararg
            vararg = a.type
            break
        end
        push!(fixed, a)
    end
    # Julia requires defaulted positional arguments to be trailing, so the
    # number of required arguments is simply the count of non-defaulted ones.
    n_req = count(a -> !a.has_default, fixed)
    out = ConcreteSig[]
    for k in n_req:length(fixed)
        push!(out, ConcreteSig([a.type for a in fixed[1:k]], nothing))
    end
    if vararg !== nothing
        # The vararg form subsumes the maximal fixed arity plus any number more.
        push!(out, ConcreteSig([a.type for a in fixed], vararg))
    end
    return out
end

"""
    signature_string(name, sig::ConcreteSig) -> String

Render a concrete signature the way a user would write the call, for reports.
"""
function signature_string(name, sig::ConcreteSig)
    parts = copy(sig.types)
    if sig.vararg !== nothing
        push!(parts, string(sig.vararg, "..."))
    end
    return string(name, "(", join(parts, ", "), ")")
end

function signature_string(name, m::MethodSig)
    parts = String[]
    for a in m.args
        s = a.type
        a.is_vararg && (s = string(s, "..."))
        a.has_default && (s = string(s, "=…"))
        push!(parts, s)
    end
    if !isempty(m.kwargs)
        kw = [string(k.name, k.is_slurp ? "..." : (k.has_default ? "=…" : "")) for k in m.kwargs]
        return string(name, "(", join(parts, ", "), "; ", join(kw, ", "), ")")
    end
    return string(name, "(", join(parts, ", "), ")")
end
