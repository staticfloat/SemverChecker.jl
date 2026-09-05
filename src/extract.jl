# Static extraction of an `APISurface` from a package directory.
#
# We deliberately parse rather than load: a CI reminder must work for the
# *previously registered* source tree too, and installing an old version's
# dependency graph just to introspect it is slow and frequently unresolvable.

const _SKIP_DIRS = Set([".git", "test", "docs", "benchmark", "examples", "deps"])

"""
    normalize_type(ex; subs=Dict()) -> String

Render a type annotation into a stable, comparable string.  `subs` maps `where`
type variables to their upper bounds so that `f(x::T) where {T<:Integer}` and
`f(x::Integer)` compare equal, and so that renaming a type variable is not
mistaken for an API change.
"""
function normalize_type(ex; subs::Dict{Symbol,Any}=Dict{Symbol,Any}())
    return string(_norm(ex, subs))
end

_norm(x, subs) = x
_norm(s::Symbol, subs) = get(subs, s, s)
function _norm(ex::Expr, subs)
    if ex.head === :curly || ex.head === :<: || ex.head === :>:
        return Expr(ex.head, map(a -> _norm(a, subs), ex.args)...)
    elseif ex.head === :.
        return ex   # qualified name, e.g. Base.AbstractVecOrMat
    elseif ex.head === :where
        # An inline `where` inside an annotation: bind then substitute.
        inner_subs = copy(subs)
        for tv in ex.args[2:end]
            name, bound = _typevar(tv)
            name === nothing || (inner_subs[name] = _norm(bound, subs))
        end
        return _norm(ex.args[1], inner_subs)
    end
    return Expr(ex.head, map(a -> _norm(a, subs), ex.args)...)
end

"""
    _typevar(ex) -> (name, upper_bound)

Decompose a `where` clause element.  `T` gives `(:T, :Any)`, `T<:Integer` gives
`(:T, :Integer)`, and `L<:T<:U` gives `(:T, :U)`.
"""
function _typevar(ex)
    if ex isa Symbol
        return (ex, :Any)
    elseif ex isa Expr && ex.head === :<: && length(ex.args) == 2
        return (ex.args[1] isa Symbol ? ex.args[1] : nothing, ex.args[2])
    elseif ex isa Expr && ex.head === :>: && length(ex.args) == 2
        return (ex.args[1] isa Symbol ? ex.args[1] : nothing, :Any)
    elseif ex isa Expr && ex.head === :comparison && length(ex.args) == 5
        # L <: T <: U
        return (ex.args[3] isa Symbol ? ex.args[3] : nothing, ex.args[5])
    end
    return (nothing, :Any)
end

"""
    _where_subs(sig_ex) -> (inner_signature, subs)

Strip any number of `where` layers off a function signature, collecting the type
variable substitutions they introduce.
"""
function _where_subs(ex)
    subs = Dict{Symbol,Any}()
    while ex isa Expr && ex.head === :where
        for tv in ex.args[2:end]
            name, bound = _typevar(tv)
            name === nothing || (subs[name] = bound)
        end
        ex = ex.args[1]
    end
    # Resolve bounds that themselves mention type variables.
    for (k, v) in subs
        subs[k] = _norm(v, filter(p -> p.first != k, subs))
    end
    return ex, subs
end

# ---------------------------------------------------------------------------
# Signature parsing
# ---------------------------------------------------------------------------

"""
    parse_signature(call_ex, subs, file, line) -> (name, MethodSig) | nothing

Turn the left-hand side of a definition into a [`MethodSig`](@ref).  Returns
`nothing` for forms we do not track (qualified names such as `Base.show`,
callable-object definitions, destructuring assignments, ...).
"""
function parse_signature(ex, subs, file, line)
    ex, more = _where_subs(ex)
    subs = merge(subs, more)
    ex isa Expr || return nothing
    if ex.head === :(::)            # return type annotation: f(x)::T = ...
        return parse_signature(ex.args[1], subs, file, line)
    end
    ex.head === :call || return nothing

    # A package may extend and re-export a function it does not own
    # (`Base.push!`, `Base.:(==)`); record those under the bare name.  Names the
    # package does not export are filtered out at comparison time, so this
    # cannot introduce noise.  `(obj::T)(args...)` has no name to record.
    fname = _defname(ex.args[1])
    fname === nothing && return nothing

    args = ArgSpec[]
    kwargs = KwSpec[]
    rest = ex.args[2:end]
    # Keyword arguments appear as a leading `Expr(:parameters, ...)`.
    if !isempty(rest) && rest[1] isa Expr && rest[1].head === :parameters
        for k in rest[1].args
            spec = _parse_kwarg(k, subs)
            spec === nothing || push!(kwargs, spec)
        end
        rest = rest[2:end]
    end
    for a in rest
        spec = _parse_posarg(a, subs)
        spec === nothing || push!(args, spec)
    end
    return (fname, MethodSig(args, kwargs, file, line))
end

"""
    _defname(ex) -> Symbol | nothing

The name a definition binds.  Unwraps qualified names (`Base.push!`) and
operator quoting (`Base.:(==)`); returns `nothing` for callable-object
definitions, which bind no name of their own.
"""
_defname(s::Symbol) = s
_defname(q::QuoteNode) = q.value isa Symbol ? q.value : nothing
function _defname(ex::Expr)
    ex.head === :. && return _defname(ex.args[end])
    ex.head === :quote && length(ex.args) == 1 && return _defname(ex.args[1])
    return nothing
end
_defname(::Any) = nothing

function _parse_posarg(a, subs)
    has_default = false
    if a isa Expr && a.head === :kw          # x = default
        has_default = true
        a = a.args[1]
    end
    is_vararg = false
    if a isa Expr && a.head === :...         # xs...
        is_vararg = true
        a = a.args[1]
    end
    ty = "Any"
    if a isa Expr && a.head === :(::)
        ty = normalize_type(a.args[end]; subs)
    elseif a isa Symbol
        ty = "Any"
    elseif a isa Expr && a.head === :tuple
        ty = "Any"                            # destructured argument
    end
    # `x::Vararg{T,N}` is spelled without `...`
    if !is_vararg && startswith(ty, "Vararg{")
        is_vararg = true
        inner = ty[8:end-1]
        ty = String(first(split(inner, ",")))
    end
    return ArgSpec(ty, has_default, is_vararg)
end

function _parse_kwarg(k, subs)
    has_default = false
    if k isa Expr && k.head === :kw
        has_default = true
        k = k.args[1]
    end
    if k isa Expr && k.head === :...
        inner = k.args[1]
        name = inner isa Expr && inner.head === :(::) ? inner.args[1] : inner
        return KwSpec(name isa Symbol ? name : :kwargs, "Any", true, true)
    end
    if k isa Expr && k.head === :(::)
        name = k.args[1]
        name isa Symbol || return nothing
        return KwSpec(name, normalize_type(k.args[end]; subs), has_default, false)
    elseif k isa Symbol
        return KwSpec(k, "Any", has_default, false)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Type definitions
# ---------------------------------------------------------------------------

function parse_typedef(ex, file, line)
    if ex.head === :struct
        ismut = ex.args[1]::Bool
        sig, subs = _where_subs(ex.args[2])
        name, params, super, subs = _split_typesig(sig, subs)
        name === nothing && return nothing
        fields = Tuple{Symbol,String}[]
        for f in ex.args[3].args
            f isa LineNumberNode && continue
            # `@kwdef` bodies carry defaults: `x::Int = 1`
            if f isa Expr && f.head === :(=)
                f = f.args[1]
            end
            if f isa Expr && f.head === :(::)
                f.args[1] isa Symbol || continue
                push!(fields, (f.args[1], normalize_type(f.args[2]; subs)))
            elseif f isa Symbol
                push!(fields, (f, "Any"))
            end
        end
        return TypeDef(name, :struct, ismut, params, super, fields, file, line)
    elseif ex.head === :abstract
        sig, subs = _where_subs(ex.args[1])
        name, params, super, subs = _split_typesig(sig, subs)
        name === nothing && return nothing
        return TypeDef(name, :abstract, false, params, super, Tuple{Symbol,String}[], file, line)
    elseif ex.head === :primitive
        sig, subs = _where_subs(ex.args[1])
        name, params, super, subs = _split_typesig(sig, subs)
        name === nothing && return nothing
        nbits = string(ex.args[2])
        return TypeDef(name, :primitive, false, params, super,
                       [(:__nbits__, nbits)], file, line)
    end
    return nothing
end

"""
    _split_typesig(ex, subs) -> (name, params, supertype, subs)

Decompose `Foo{T<:Real} <: Bar` into its pieces.  The returned `subs` adds the
type parameters bound by the `{...}` clause, so that field annotations mentioning
them normalize to their bounds rather than to the parameter's spelling.
"""
function _split_typesig(ex, subs)
    super_ex = nothing
    if ex isa Expr && ex.head === :<:
        super_ex = ex.args[2]
        ex = ex.args[1]
    end
    params = String[]
    subs = copy(subs)
    if ex isa Expr && ex.head === :curly
        for p in ex.args[2:end]
            name, bound = _typevar(p)
            name === nothing || (subs[name] = bound)
        end
        for p in ex.args[2:end]
            _, bound = _typevar(p)
            push!(params, normalize_type(bound; subs))
        end
        ex = ex.args[1]
    end
    super = super_ex === nothing ? "Any" : normalize_type(super_ex; subs)
    return (ex isa Symbol ? ex : nothing), params, super, subs
end

# ---------------------------------------------------------------------------
# Walking a package
# ---------------------------------------------------------------------------

mutable struct _Walker
    root::String
    surface_exports::Set{Symbol}
    surface_publics::Set{Symbol}
    functions::Dict{Symbol,Vector{MethodSig}}
    macros::Dict{Symbol,Vector{MethodSig}}
    types::Dict{Symbol,TypeDef}
    consts::Dict{Symbol,ConstDef}
    visited::Set{String}
    errors::Vector{String}
end

_Walker(root) = _Walker(root, Set{Symbol}(), Set{Symbol}(),
    Dict{Symbol,Vector{MethodSig}}(), Dict{Symbol,Vector{MethodSig}}(),
    Dict{Symbol,TypeDef}(), Dict{Symbol,ConstDef}(), Set{String}(), String[])

_rel(w::_Walker, file) = relpath(file, w.root)

function _walk_file!(w::_Walker, file::String)
    file = abspath(file)
    (file in w.visited || !isfile(file)) && return
    push!(w.visited, file)
    src = try
        read(file, String)
    catch e
        push!(w.errors, "could not read $(_rel(w, file)): $(e)")
        return
    end
    ast = try
        Meta.parseall(src; filename=file)
    catch e
        push!(w.errors, "could not parse $(_rel(w, file)): $(sprint(showerror, e))")
        return
    end
    _walk!(w, ast, file, 0, Dict{Symbol,Any}())
end

"""
    _walk!(w, ex, file, line, subs)

Recursive top-level walker.  `subs` carries `where`-bound type variables down
into nested definitions.
"""
function _walk!(w::_Walker, ex, file::String, line::Int, subs)
    ex isa Expr || return
    h = ex.head

    if h === :toplevel || h === :block
        for a in ex.args
            if a isa LineNumberNode
                line = a.line
            else
                _walk!(w, a, file, line, subs)
            end
        end
        return
    elseif h === :module
        # ex.args = (std_imports::Bool, name::Symbol, body)
        _walk!(w, ex.args[3], file, line, subs)
        return
    elseif h === :export
        for s in ex.args
            s isa Symbol && push!(w.surface_exports, s)
        end
        return
    elseif h === :public
        for s in ex.args
            s isa Symbol && push!(w.surface_publics, s)
        end
        return
    elseif h === :macrocall
        _walk_macrocall!(w, ex, file, line, subs)
        return
    elseif h === :struct || h === :abstract || h === :primitive
        td = parse_typedef(ex, _rel(w, file), line)
        td === nothing || (w.types[td.name] = td)
        return
    elseif h === :function || (h === :(=) && _is_def(ex))
        isempty(ex.args) && return
        parsed = parse_signature(ex.args[1], subs, _rel(w, file), line)
        if parsed !== nothing
            name, sig = parsed
            push!(get!(Vector{MethodSig}, w.functions, name), sig)
        end
        return
    elseif h === :macro
        parsed = parse_signature(ex.args[1], subs, _rel(w, file), line)
        if parsed !== nothing
            name, sig = parsed
            push!(get!(Vector{MethodSig}, w.macros, Symbol("@", name)), sig)
        end
        return
    elseif h === :const
        _walk_const!(w, ex.args[1], file, line, subs)
        return
    elseif h === :where
        # `f(x::T) where T = ...` reaches us via :(=); a bare :where at
        # top-level is a stray annotation.  Recurse just in case.
        _walk!(w, ex.args[1], file, line, subs)
        return
    elseif h === :call && !isempty(ex.args) && ex.args[1] === :include
        _walk_include!(w, ex, file, line, subs)
        return
    elseif h === :if || h === :elseif || h === :try || h === :for || h === :let
        # Conditionally-defined API (version gates, platform gates).  Walk every
        # branch: the union over branches is the right over-approximation here.
        for a in ex.args
            _walk!(w, a, file, line, subs)
        end
        return
    end
    return
end

"""
    _is_def(ex) -> Bool

Distinguish the short-form function definition `f(x) = ...` from an ordinary
assignment `x = ...`.
"""
function _is_def(ex::Expr)
    lhs = ex.args[1]
    while lhs isa Expr && (lhs.head === :where || lhs.head === :(::))
        lhs = lhs.args[1]
    end
    return lhs isa Expr && lhs.head === :call
end

function _walk_const!(w::_Walker, ex, file, line, subs)
    ex isa Expr || return
    if ex.head === :(=)
        lhs = ex.args[1]
        ty = ""
        if lhs isa Expr && lhs.head === :(::)
            ty = normalize_type(lhs.args[2]; subs)
            lhs = lhs.args[1]
        end
        if lhs isa Symbol
            w.consts[lhs] = ConstDef(lhs, ty, _rel(w, file), line)
        end
    elseif ex.head === :global || ex.head === :local
        for a in ex.args
            _walk_const!(w, a, file, line, subs)
        end
    end
end

"""
    _walk_include!(w, ex, ...)

Follow `include("path.jl")`.  Non-literal include targets (computed paths,
`include` inside loops) cannot be resolved statically and are recorded so the
report can say the surface is incomplete.
"""
function _walk_include!(w::_Walker, ex, file, line, subs)
    length(ex.args) == 2 || return
    target = ex.args[2]
    if target isa String
        _walk_file!(w, joinpath(dirname(file), target))
    else
        push!(w.errors, "unresolved include at $(_rel(w, file)):$(line)")
    end
end

"""
    _walk_macrocall!(w, ex, ...)

Handle the macros that commonly *define* public API.  Anything else is walked
through so that e.g. `@doc`-wrapped or `@static`-guarded definitions are still
seen; macros that generate definitions from data (`@eval` loops) are invisible
to static analysis and are noted as such.
"""
function _walk_macrocall!(w::_Walker, ex, file, line, subs)
    isempty(ex.args) && return
    m = ex.args[1]
    mname = m isa Expr && m.head === :. ? m.args[end] : m
    mname = mname isa QuoteNode ? mname.value : mname
    name = string(mname)

    if name == "@enum" || name == "@enumx"
        _walk_enum!(w, ex, file, line)
        return
    elseif name == "@eval" || name == "@generated"
        # `@eval` bodies are usually metaprogrammed API; record the gap unless
        # the body is a plain definition we can read directly.
        for a in ex.args[2:end]
            if a isa Expr && a.head in (:function, :struct, :abstract, :(=), :macro)
                _walk!(w, a, file, line, subs)
            elseif !(a isa LineNumberNode) && !(a isa Symbol)
                push!(w.errors, "`$(name)` block at $(_rel(w, file)):$(line) not analyzed statically")
            end
        end
        return
    end
    # `@kwdef struct ...`, `@doc "..." f(x) = ...`, `@static if ... end`,
    # `Base.@deprecate`, custom definition macros: walk the argument list.
    for a in ex.args[2:end]
        a isa LineNumberNode && continue
        _walk!(w, a, file, line, subs)
    end
end

function _walk_enum!(w::_Walker, ex, file, line)
    args = filter(a -> !(a isa LineNumberNode), ex.args[2:end])
    isempty(args) && return
    head = args[1]
    tyname = head
    super = "Int32"
    if head isa Expr && head.head === :(::)
        tyname = head.args[1]
        super = normalize_type(head.args[2])
    end
    tyname isa Symbol || return
    w.types[tyname] = TypeDef(tyname, :abstract, false, String[],
                              "Enum{$(super)}", Tuple{Symbol,String}[], _rel(w, file), line)
    for member in args[2:end]
        m = member
        m isa Expr && m.head === :(=) && (m = m.args[1])
        if m isa Symbol
            w.consts[m] = ConstDef(m, string(tyname), _rel(w, file), line)
        elseif m isa Expr && m.head === :block
            for mm in m.args
                mm isa LineNumberNode && continue
                mm isa Expr && mm.head === :(=) && (mm = mm.args[1])
                mm isa Symbol && (w.consts[mm] = ConstDef(mm, string(tyname), _rel(w, file), line))
            end
        end
    end
end

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

"""
    extract_surface(pkgdir) -> APISurface

Statically analyze the package rooted at `pkgdir` and return its public API
surface.  Requires `pkgdir/Project.toml` with a `name`, and an entry point at
`pkgdir/src/<name>.jl`.
"""
function extract_surface(pkgdir::AbstractString)
    pkgdir = abspath(pkgdir)
    proj_path = joinpath(pkgdir, "Project.toml")
    isfile(proj_path) || throw(ArgumentError("no Project.toml in $(pkgdir)"))
    proj = TOML.parsefile(proj_path)
    name = get(proj, "name", nothing)
    name === nothing && throw(ArgumentError("Project.toml in $(pkgdir) has no `name`"))
    uuid = haskey(proj, "uuid") ? Base.UUID(proj["uuid"]) : nothing
    version = haskey(proj, "version") ? VersionNumber(proj["version"]) : nothing

    w = _Walker(pkgdir)
    entry = joinpath(pkgdir, "src", "$(name).jl")
    if isfile(entry)
        _walk_file!(w, entry)
    else
        push!(w.errors, "missing entry point src/$(name).jl")
    end
    # Package extensions are part of the loadable surface too.
    extdir = joinpath(pkgdir, "ext")
    if isdir(extdir)
        for f in readdir(extdir; join=true)
            isfile(f) && endswith(f, ".jl") && _walk_file!(w, f)
        end
    end

    # Names the package advertises but does not define here — reexports from a
    # dependency, or bindings built at runtime.  They are still compared by
    # name (so dropping one is caught), but their signatures are invisible;
    # say so rather than quietly claiming full coverage.
    advertised = union(w.surface_exports, w.surface_publics)
    unresolved = sort!(String[string(n) for n in advertised
                              if !haskey(w.functions, n) && !haskey(w.macros, n) &&
                                 !haskey(w.types, n) && !haskey(w.consts, n)])
    if !isempty(unresolved)
        shown = join(first(unresolved, 8), ", ")
        length(unresolved) > 8 && (shown *= ", …")
        push!(w.errors, "$(length(unresolved)) of $(length(advertised)) public name(s) are " *
                        "not defined in this package (reexported or generated); compared by " *
                        "name only: $(shown)")
    end

    return APISurface(name, uuid, version, w.surface_exports, w.surface_publics,
                      w.functions, w.macros, w.types, w.consts,
                      source_hash(pkgdir), w.errors)
end

"""
    source_hash(pkgdir) -> String

A content hash over everything that can affect behaviour: `src/`, `ext/` and the
non-version fields of `Project.toml`.  Used to recognise a package that has not
been touched at all since its last release, which needs no version bump.
"""
function source_hash(pkgdir::AbstractString)
    ctx = SHA.SHA256_CTX()
    for sub in ("src", "ext")
        dir = joinpath(pkgdir, sub)
        isdir(dir) || continue
        files = String[]
        for (root, _, fs) in walkdir(dir)
            for f in fs
                endswith(f, ".jl") && push!(files, joinpath(root, f))
            end
        end
        for f in sort(files; by = p -> relpath(p, pkgdir))
            SHA.update!(ctx, codeunits(relpath(f, pkgdir)))
            SHA.update!(ctx, read(f))
        end
    end
    proj_path = joinpath(pkgdir, "Project.toml")
    if isfile(proj_path)
        proj = TOML.parsefile(proj_path)
        delete!(proj, "version")
        io = IOBuffer()
        TOML.print(io, proj; sorted=true)
        SHA.update!(ctx, take!(io))
    end
    return bytes2hex(SHA.digest!(ctx))
end
