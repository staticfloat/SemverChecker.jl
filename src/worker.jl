# Self-contained worker: extracts API surfaces from *loaded* packages, and
# compares an old surface against the live new one using real Julia subtyping.
#
# This file must not depend on SemverChecker or on anything outside the standard
# library: it is `include`d into a bare subprocess that has the packages under
# analysis loaded, and loading SemverChecker's own dependencies alongside them
# could perturb resolution.  SemverChecker itself includes it too, so the rules
# below are unit-testable in-process.

module SemverWorker

using Serialization, SHA, TOML, Pkg

# ---------------------------------------------------------------------------
# Rendering types so they can be re-evaluated elsewhere
# ---------------------------------------------------------------------------

"""
    qualify(T) -> String

Render a type with every name fully qualified, so the string can be parsed and
evaluated in another process against a different version of the package.

`:module => nothing` is what forces qualification: without it Julia abbreviates
names that happen to be in scope, and the result is ambiguous.
"""
qualify(@nospecialize(T)) = sprint(show, T; context = :module => nothing)

"""
    is_stdlib_module(mod) -> Bool

Whether `mod` belongs to Base, Core or a standard library.

Methods owned by such modules are excluded from a package's surface: they are
not the package's API, and since both sides of the comparison run on the same
Julia they can never differ.  Crucially this keeps methods a package *adds* to
`Base.push!` — those are owned by the package, not by Base.
"""
function is_stdlib_module(mod::Module)
    root = Base.moduleroot(mod)
    (root === Base || root === Core) && return true
    p = Base.pathof(root)
    # A module with no path is not a standard library — it is something defined
    # at the REPL or by `@eval`.  Treating it as one would silently drop it.
    p === nothing && return false
    return startswith(abspath(p), abspath(Sys.STDLIB))
end

"""
    is_visible_from(mod, M) -> Bool

Whether methods defined in `mod` belong to `M`'s API surface.

This matters because a generic function is shared by everyone who extends it.
`BinaryBuilderGitUtils` does `import Base.BinaryPlatforms: tags` and adds a
method, so `methods(BinaryBuilderGitUtils.tags)` also returns every `tags`
method added by every *other* package that happens to be loaded — which, since
we deliberately load a whole monorepo at once, is a lot of them.

A method counts as part of `M`'s surface when it is defined by `M` itself or by
something `M` can see: `using Foo` binds `Foo` inside `M`, so a reexported
`Foo.bar` method is included, while a sibling package that merely happens to be
co-loaded is not.
"""
function is_visible_from(mod::Module, M::Module)
    root = Base.moduleroot(mod)
    root === Base.moduleroot(M) && return true
    nm = nameof(root)
    return isdefined(M, nm) && getglobal(M, nm) === root
end

# ---------------------------------------------------------------------------
# Extracting a surface from a loaded module
# ---------------------------------------------------------------------------


"""
    _collect!(entries, exported, publics, M, root, prefix, seen)

Record every public name of `M`, descending into public *sub*modules under a
dotted prefix (`Inner.thing`).

A public submodule's exports are reachable as `Package.Inner.thing` and are
therefore part of the package's API.  Modules from *other* packages that happen
to be reexported are skipped: they are checked as packages in their own right,
and pulling their whole surface in here would duplicate every finding.
"""
function _collect!(entries, exported, publics, M::Module, root::Module,
                   prefix::AbstractString, seen::Set{Module})
    for n in names(M)
        n === nameof(M) && continue
        isdefined(M, n) || continue
        v = try
            getglobal(M, n)
        catch
            continue
        end
        qname = string(prefix, n)
        if _isexported(M, n)
            push!(exported, qname)
        else
            push!(publics, qname)
        end
        entries[qname] = try
            describe(v, root)
        catch e
            Dict{String,Any}("kind" => "unknown", "error" => first(sprint(showerror, e), 200))
        end
        if v isa Module && !(v in seen) && Base.moduleroot(v) === Base.moduleroot(root)
            push!(seen, v)
            _collect!(entries, exported, publics, v, root, string(qname, "."), seen)
        end
    end
    return nothing
end

"""
    surface_of(M::Module) -> Dict{String,Any}

The public API surface of a loaded package, as plain data.

`names(M)` is the real, post-load answer: it includes names reexported from
dependencies (`@reexport using Foo`) and names bound by code generation, which
is precisely what reading the source cannot tell you.
"""
function surface_of(M::Module)
    exported = String[]
    publics = String[]
    entries = Dict{String,Any}()
    _collect!(entries, exported, publics, M, M, "", Set{Module}([M]))
    dir = try
        Base.pkgdir(M)
    catch
        nothing
    end
    return Dict{String,Any}(
        "name" => string(nameof(M)),
        "exported" => sort!(exported),
        "public" => sort!(publics),
        "entries" => entries,
        "source_hash" => dir === nothing ? "" : source_hash(dir),
        "version" => dir === nothing ? "" : project_version(dir),
    )
end

# `public` (and thus the exported/public split) only exists from Julia 1.11.
_isexported(M, n) = isdefined(Base, :isexported) ? Base.isexported(M, n) : true

function describe(@nospecialize(v), M::Module)
    v isa Module && return Dict{String,Any}("kind" => "module", "repr" => string(v))
    v isa Type && return describe_type(v)
    # Callable objects are part of the API even when they are not `<: Function`.
    if v isa Function || !isempty(methods(v))
        return describe_function(v, M)
    end
    return Dict{String,Any}("kind" => "const", "type" => qualify(typeof(v)))
end

function describe_type(@nospecialize(v))
    d = Dict{String,Any}("kind" => "type", "repr" => qualify(v))
    base = Base.unwrap_unionall(v)
    if !(base isa DataType)
        # A `Union` alias, e.g. `const HashOrString = Union{String,MultiHash}`.
        d["form"] = "union"
        return d
    end
    d["form"] = isabstracttype(base) ? "abstract" :
                isprimitivetype(base) ? "primitive" : "struct"
    d["mutable"] = ismutabletype(base)
    d["nparams"] = length(base.parameters)
    d["module"] = string(base.name.module)
    d["supertype"] = qualify(supertype(base))
    if isprimitivetype(base)
        d["nbits"] = 8 * sizeof(base)
    end
    # A type's *constructors* are its public interface; its field layout is an
    # implementation detail that callers are not supposed to rely on (see the
    # note on `_compare_type!`).  Recording constructors also means a change of
    # layout is still caught whenever it actually reaches callers, because the
    # default constructor's signature changes with it.
    d["constructors"] = _entries(constructor_methods(v, parentmodule(base)))
    return d
end

"""
    _entries(ms) -> Vector{Dict}

Render a list of `Method`s as plain data.
"""
function _entries(ms)
    out = Dict{String,Any}[]
    for m in ms
        kw = try
            String[string(k) for k in Base.kwarg_decl(m)]
        catch
            String[]
        end
        push!(out, Dict{String,Any}(
            "sig" => qualify(m.sig),
            "kwargs" => sort!(kw),
            "file" => string(m.file),
            "line" => m.line,
            "module" => string(m.module),
        ))
    end
    sort!(out; by = m -> m["sig"])
    return out
end

"""
    own_methods(callable, M) -> Vector{Method}

The methods of `callable` that belong to `M`'s surface.
"""
own_methods(@nospecialize(v), M::Module) =
    [m for m in methods(v) if !is_stdlib_module(m.module) && is_visible_from(m.module, M)]

_method_entries(@nospecialize(v), M::Module) = _entries(own_methods(v, M))

"""
    _sig_args(sig) -> Vector

The argument types of a method signature, dropping the callee slot.
"""
function _sig_args(@nospecialize(sig))
    s = Base.unwrap_unionall(sig)
    s isa DataType || return Any[]
    return Any[s.parameters[i] for i in 2:length(s.parameters)]
end

"""
    is_generated_fallback(T, m, siblings) -> Bool

Whether `m` is the converting constructor the compiler generates for a struct
with typed fields.

Julia emits two constructors for `struct S; a::Int; end`: `S(::Int)`, and
`S(::Any)` which calls `convert`. The second accepts *anything*, so counting it
when asking "is this released constructor still callable?" makes the question
vacuous — `S(::String)` looks alive long after it was deleted, because `S(::Any)`
swallows the call and only then fails inside `convert`. Worse, it hides every
field *type* change, since `S(::Any)` covers the old typed signature too.

It is identified by shape rather than guessed at: all-`Any` arguments, one per
field, sharing a source location with a sibling constructor that spells the
field types out. A hand-written untyped constructor lives on its own line and is
therefore kept.
"""
function is_generated_fallback(@nospecialize(T), m, siblings)
    (T isa DataType && isstructtype(T)) || return false
    n = fieldcount(T)
    n == 0 && return false
    args = _sig_args(m.sig)
    (length(args) == n && all(a -> a === Any, args)) || return false
    return any(siblings) do other
        other === m && return false
        other.file == m.file && other.line == m.line || return false
        oargs = _sig_args(other.sig)
        length(oargs) == n && any(a -> a !== Any, oargs)
    end
end

"""
    constructor_methods(T, M) -> Vector{Method}

`T`'s constructors, minus the compiler's converting fallback.
"""
function constructor_methods(@nospecialize(T), M::Module)
    ms = own_methods(T, M)
    return [m for m in ms if !is_generated_fallback(T, m, ms)]
end

describe_function(@nospecialize(v), M::Module) =
    Dict{String,Any}("kind" => "function", "methods" => _method_entries(v, M))

# ---------------------------------------------------------------------------
# Comparison — runs in the process where the NEW version is loaded
# ---------------------------------------------------------------------------


"""
    _resolve(M, dotted) -> value | nothing

Look up a possibly dotted name (`Inner.thing`) recorded by [`_collect!`](@ref).
"""
function _resolve(M::Module, dotted::AbstractString)
    cur::Any = M
    for part in split(dotted, '.')
        sym = Symbol(part)
        (cur isa Module && isdefined(cur, sym)) || return nothing
        cur = getglobal(cur, sym)
    end
    return cur
end

const MAJOR = "major"
const MINOR = "minor"

_change(level, kind, name, detail, loc="") =
    Dict{String,Any}("level" => level, "kind" => kind, "name" => string(name),
                     "detail" => detail, "location" => loc)

const _SCOPE = Ref{Union{Nothing,Module}}(nothing)

"""
    eval_scope() -> Module

A scratch module in which every loaded root module is bound under its own name.

Recorded signatures are fully qualified (`BinaryBuilderSources.JLLSource`), so
evaluating one requires its root module to be in scope.  The package's own
module is *not* a sufficient scope: it only sees its own dependencies, and a
surface legitimately mentions types from anywhere in the loaded set.
"""
function eval_scope()
    m = _SCOPE[]
    m === nothing || return m
    m = Module(:SemverEvalScope)
    for (pkgid, mod) in Base.loaded_modules
        mod isa Module || continue
        nm = Symbol(pkgid.name)
        isdefined(m, nm) && continue
        try
            Core.eval(m, :(const $(nm) = $(mod)))
        catch
            # A name that cannot be bound simply stays unresolvable.
        end
    end
    _SCOPE[] = m
    return m
end

"""
    tryeval(s) -> (value, ok)

Evaluate a type expression recorded from the released version against the newly
loaded world.

Failure is meaningful, not incidental — it means a type the old signature named
no longer exists under that name, which is itself a breaking change.
"""
function tryeval(s::AbstractString)
    try
        return (Core.eval(eval_scope(), Meta.parse(s)), true)
    catch
        return (nothing, false)
    end
end

"""
    compare(old::Dict, M::Module) -> Vector{Dict}

Diff the recorded surface `old` against the live module `M`, using real
subtyping rather than textual comparison of annotations.
"""
function compare(old::Dict, M::Module)
    changes = Dict{String,Any}[]
    new = surface_of(M)
    old_public = Set{String}(vcat(old["exported"], old["public"]))
    new_public = Set{String}(vcat(new["exported"], new["public"]))

    for n in sort!(collect(setdiff(old_public, new_public)))
        push!(changes, _change(MAJOR, "export_removed", n, "`$(n)` is no longer public"))
    end
    for n in sort!(collect(setdiff(new_public, old_public)))
        push!(changes, _change(MINOR, "export_added", n, "`$(n)` is newly public",
                               _location(new["entries"], n)))
    end
    for n in sort!(collect(intersect(old_public, new_public)))
        _compare_entry!(changes, M, n, old["entries"][n], new["entries"][n])
    end
    return changes
end

function _location(entries, n)
    e = get(entries, n, nothing)
    e === nothing && return ""
    if get(e, "kind", "") == "function" && !isempty(e["methods"])
        m = e["methods"][1]
        return string(m["file"], ":", m["line"])
    end
    return ""
end

function _compare_entry!(changes, M::Module, n, oe::Dict, ne::Dict)
    ok, nk = get(oe, "kind", "unknown"), get(ne, "kind", "unknown")
    (ok == "unknown" || nk == "unknown") && return
    if ok != nk
        push!(changes, _change(MAJOR, "kind_changed", n,
                               "`$(n)` changed from a $(ok) to a $(nk)"))
        return
    end
    if nk == "function"
        _compare_function!(changes, M, n, oe, ne)
    elseif nk == "type"
        _compare_type!(changes, M, n, oe, ne)
    elseif nk == "const"
        if oe["type"] != ne["type"]
            push!(changes, _change(MAJOR, "const_type_changed", n,
                                   "`$(n)` changed type: `$(oe["type"])` → `$(ne["type"])`"))
        end
    end
end

"""
    _compare_function!(changes, M, n, oe, ne)

For every method the released version had, ask Julia whether a call it accepted
is still dispatched: `S_old <: m.sig` for some method `m` of the new function.
This is the real dispatch rule, so widening (`Int` → `Integer`, growing a
`Union`, adding a type parameter bound) is recognised as non-breaking without
any special-casing.
"""
function _compare_function!(changes, M::Module, n, oe::Dict, ne::Dict)
    f = _resolve(M, n)
    f === nothing && return
    new_methods = own_methods(f, M)
    _compare_methodset!(changes, n, oe["methods"], new_methods, "method")
    _compare_kwargs!(changes, n, oe, ne, "methods", "keyword argument")
end

"""
    _compare_methodset!(changes, name, old_entries, new_methods, noun)

Ask Julia, for every method the released version had, whether a call it accepted
is still dispatched: `S_old <: m.sig` for some current method.  This is the real
dispatch rule, so widening (`Int` → `Integer`, growing a `Union`, loosening a
type parameter's bound) is recognised as non-breaking without special-casing.

Used for both plain functions and constructors, which differ only in wording.
"""
function _compare_methodset!(changes, name, old_entries, new_methods, noun::String)
    new_sigs = Any[m.sig for m in new_methods]
    old_sigs = Any[]
    for om in old_entries
        S, ok = tryeval(om["sig"])
        if !ok
            push!(changes, _change(MAJOR, "signature_unresolvable", name,
                                   "a type named by the released $(noun) " *
                                   "`$(_pretty(om["sig"]))` no longer exists"))
            continue
        end
        push!(old_sigs, S)
        if !any(s -> S <: s, new_sigs)
            push!(changes, _change(MAJOR, "$(noun)_removed", name,
                                   "no $(noun) accepts `$(_pretty(om["sig"]))` any more"))
        end
    end
    for m in new_methods
        any(S -> m.sig <: S, old_sigs) && continue
        push!(changes, _change(MINOR, "$(noun)_added", name,
                               "new $(noun) `$(_pretty(qualify(m.sig)))`",
                               string(m.file, ":", m.line)))
    end
    return nothing
end

function _compare_kwargs!(changes, n, oe::Dict, ne::Dict, key::String, noun::String)
    oldkw = Set{String}(); newkw = Set{String}()
    for m in get(oe, key, Any[]); union!(oldkw, m["kwargs"]); end
    for m in get(ne, key, Any[]); union!(newkw, m["kwargs"]); end
    # `kwargs...` absorbs anything, so a slurping method removes nothing.
    slurps = any(endswith(k, "...") for k in newkw)
    for k in sort!(collect(setdiff(oldkw, newkw)))
        endswith(k, "...") && continue
        slurps && continue
        push!(changes, _change(MAJOR, "kwarg_removed", n,
                               "$(noun) `$(k)` of `$(n)` was removed"))
    end
    for k in sort!(collect(setdiff(newkw, oldkw)))
        endswith(k, "...") && continue
        # The method table records keyword *names* but not their defaults, so we
        # cannot tell a new required keyword from a new optional one.
        push!(changes, _change(MINOR, "kwarg_added", n,
                               "new $(noun) `$(k)` on `$(n)`"))
    end
end

function _compare_type!(changes, M::Module, n, oe::Dict, ne::Dict)
    of, nf = get(oe, "form", ""), get(ne, "form", "")
    if of != nf
        push!(changes, _change(MAJOR, "type_form_changed", n,
                               "`$(n)` changed from `$(of)` to `$(nf)`"))
        return
    end
    of == "union" && return _compare_union!(changes, M, n, oe, ne)

    if get(oe, "mutable", false) != get(ne, "mutable", false)
        push!(changes, _change(MAJOR, "mutability_changed", n,
                               "`$(n)` became $(ne["mutable"] ? "mutable" : "immutable")"))
    end
    if get(oe, "nparams", 0) != get(ne, "nparams", 0)
        push!(changes, _change(MAJOR, "type_params_changed", n,
                               "`$(n)` now takes $(ne["nparams"]) type parameter(s), " *
                               "was $(oe["nparams"])"))
    end
    # The released supertype is a real contract: code wrote `x isa OldSuper`.
    # It only breaks if the new type no longer satisfies it.
    if oe["supertype"] != ne["supertype"]
        Sold, ok = tryeval(oe["supertype"])
        Tnew, ok2 = tryeval(ne["repr"])
        still = ok && ok2 && (Tnew <: Sold)
        if !still
            push!(changes, _change(MAJOR, "supertype_changed", n,
                                   "`$(n)` no longer subtypes `$(_pretty(oe["supertype"]))` " *
                                   "(now `$(_pretty(ne["supertype"]))`)"))
        end
    end
    # Deliberately *not* compared: the field list.  Julia convention treats a
    # struct's fields and their types as an implementation detail that callers
    # should not rely on — `propertynames` is the documented interface — so
    # diffing the layout reports private churn as a breaking change.  What
    # callers actually depend on is the constructor, and a layout change that
    # does reach them shows up there: adding a field to a struct with the
    # generated constructor turns `S(a, b)` into `S(a, b, c)`, while adding one
    # behind an explicit inner constructor rightly changes nothing.
    T = _resolve(M, n)
    if T isa Type
        new_ctors = constructor_methods(T, M)
        _compare_methodset!(changes, n, get(oe, "constructors", Any[]), new_ctors, "constructor")
        _compare_kwargs!(changes, n, oe, ne, "constructors", "constructor keyword")
    end
end

function _compare_union!(changes, M::Module, n, oe::Dict, ne::Dict)
    oe["repr"] == ne["repr"] && return
    Uold, ok = tryeval(oe["repr"])
    Unew = _resolve(M, n)
    # A union alias that only grew still accepts everything it used to.
    if ok && Unew isa Type && Uold <: Unew
        push!(changes, _change(MINOR, "union_widened", n,
                               "`$(n)` widened to `$(_pretty(ne["repr"]))`"))
    else
        push!(changes, _change(MAJOR, "union_changed", n,
                               "`$(n)` changed: `$(_pretty(oe["repr"]))` → `$(_pretty(ne["repr"]))`"))
    end
end

"""
    _pretty(s) -> String

Strip the noise that full qualification adds, and render a signature the way a
caller would write it.  Display only — comparisons always use the fully
qualified form.
"""
function _pretty(s::AbstractString)
    s = replace(s, "Core." => "", "Base." => "")
    # A signature may be a UnionAll; set the `where` clause aside while
    # rewriting the tuple, then put it back.
    where_clause = ""
    m0 = match(r"^(.*?)( where .*)$", s)
    if m0 !== nothing
        s, where_clause = String(m0[1]), String(m0[2])
    end
    call = _split_call(s)
    call === nothing && return s * where_clause
    callee, args = call
    return string(callee, "(", args, ")", where_clause)
end

"""
    _split_call(s) -> (callee, args) | nothing

Split `Tuple{typeof(f), A, B}` (a method) or `Tuple{Type{T}, A, B}` (a
constructor) into the thing being called and its argument list.

The scan tracks brace depth rather than using a regex, because the callee can
itself contain commas and braces, as in `Tuple{Type{P{T,U}}, T}`.
"""
function _split_call(s::AbstractString)
    (startswith(s, "Tuple{") && endswith(s, "}")) || return nothing
    body = s[7:prevind(s, lastindex(s))]
    depth = 0
    comma = 0
    for (i, c) in pairs(body)
        if c == '{' || c == '('
            depth += 1
        elseif c == '}' || c == ')'
            depth -= 1
        elseif c == ',' && depth == 0
            comma = i
            break
        end
    end
    head = strip(comma == 0 ? body : body[1:prevind(body, comma)])
    args = comma == 0 ? "" : strip(body[nextind(body, comma):end])
    callee = if startswith(head, "typeof(") && endswith(head, ")")
        head[8:prevind(head, lastindex(head))]
    elseif startswith(head, "Type{") && endswith(head, "}")
        head[6:prevind(head, lastindex(head))]
    else
        return nothing
    end
    return (callee, args)
end

# ---------------------------------------------------------------------------
# Source hashing — recognising a package that has not been touched at all
# ---------------------------------------------------------------------------

"""
    source_hash(pkgdir) -> String

Content hash over `src/`, `ext/` and the non-version fields of `Project.toml`.
A package whose hash matches its release needs no bump at all.
"""
function source_hash(pkgdir::AbstractString)
    ctx = SHA.SHA256_CTX()
    for sub in ("src", "ext")
        dir = joinpath(pkgdir, sub)
        isdir(dir) || continue
        files = String[]
        for (root, _, fs) in walkdir(dir), f in fs
            endswith(f, ".jl") && push!(files, joinpath(root, f))
        end
        for f in sort(files; by = p -> relpath(p, pkgdir))
            SHA.update!(ctx, codeunits(replace(relpath(f, pkgdir), '\\' => '/')))
            SHA.update!(ctx, read(f))
        end
    end
    proj = joinpath(pkgdir, "Project.toml")
    if isfile(proj)
        d = TOML.parsefile(proj)
        delete!(d, "version")
        io = IOBuffer()
        TOML.print(io, d; sorted = true)
        SHA.update!(ctx, take!(io))
    end
    return bytes2hex(SHA.digest!(ctx))
end

function project_version(pkgdir::AbstractString)
    proj = joinpath(pkgdir, "Project.toml")
    isfile(proj) || return ""
    return string(get(TOML.parsefile(proj), "version", ""))
end

# ---------------------------------------------------------------------------
# Subprocess entry point
# ---------------------------------------------------------------------------

_load(name) = @eval (using $(Symbol(name)); $(Symbol(name)))

"""
    run_request(req::Dict) -> Dict

Executed inside a bare subprocess.  `mode` is either `"dump"` (install the given
registered versions and record their surfaces) or `"compare"` (develop the given
working-tree paths and diff them against the recorded surfaces).
"""
function run_request(req::Dict)
    out = Dict{String,Any}()
    specs = req["specs"]
    _setup(req["mode"], specs, out)

    # Load *everything* before extracting anything.  A generic function's method
    # table grows as packages are loaded, so a surface taken mid-way through the
    # loop would depend on load order — and the two sides of the comparison would
    # disagree for reasons that have nothing to do with the release.
    mods = Dict{String,Module}()
    for s in specs
        name = s["name"]
        haskey(out, name) && continue          # already recorded a resolve failure
        try
            mods[name] = _load(name)
        catch e
            out[name] = Dict{String,Any}("error" => "could not load: " *
                                         first(sprint(showerror, e), 300))
        end
    end

    old = get(req, "old", Dict{String,Any}())
    for s in specs
        name = s["name"]
        M = get(mods, name, nothing)
        M === nothing && continue
        out[name] = try
            surf = surface_of(M)
            if req["mode"] == "compare" && haskey(old, name)
                surf["changes"] = compare(old[name], M)
            end
            surf
        catch e
            Dict{String,Any}("error" => "analysis failed: " * first(sprint(showerror, e), 300))
        end
    end
    return out
end

"""
    _setup(mode, specs, out)

Put every package into one environment: all the registered versions for `dump`,
all the working-tree paths for `compare`.  Resolving the set together is what
makes a monorepo cost two loads rather than two per package.

If the set will not resolve together — which happens exactly when a working-tree
version has outgrown a sibling's compat bound, i.e. while the developer is in
the middle of doing what this tool asked — the environment is rebuilt one
package at a time so that the one package at fault is the only one that loses
its verdict.
"""
function _setup(mode::AbstractString, specs, out)
    Pkg.activate(; temp = true, io = devnull)
    try
        _setup_all(mode, specs)
        return
    catch e
        @debug "batch resolution failed; adding packages one at a time" exception = e
    end
    Pkg.activate(; temp = true, io = devnull)
    for s in specs
        try
            _setup_one(mode, s)
        catch e
            out[s["name"]] = Dict{String,Any}(
                "error" => "could not be resolved alongside the other packages " *
                           "(a compat bound may need updating too): " *
                           first(sprint(showerror, e), 300))
        end
    end
    return nothing
end

_spec(s) = haskey(s, "path") ? Pkg.PackageSpec(path = s["path"]) :
           Pkg.PackageSpec(name = s["name"], version = VersionNumber(s["version"]))

function _setup_all(mode::AbstractString, specs)
    specs_ = [_spec(s) for s in specs]
    mode == "dump" ? Pkg.add(specs_; io = devnull) : Pkg.develop(specs_; io = devnull)
end

function _setup_one(mode::AbstractString, s)
    mode == "dump" ? Pkg.add(_spec(s); io = devnull) : Pkg.develop(_spec(s); io = devnull)
end

function main()
    req = Serialization.deserialize(ARGS[1])
    resp = try
        run_request(req)
    catch e
        Dict{String,Any}("__fatal__" => sprint(showerror, e, catch_backtrace()))
    end
    Serialization.serialize(ARGS[2], resp)
    return 0
end

end # module SemverWorker
