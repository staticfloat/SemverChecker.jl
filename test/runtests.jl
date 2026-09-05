using Test, UUIDs
using SemverChecker
using SemverChecker: NoChange, Patch, Minor, Major, bump_version, is_sufficient,
                     Change, overall_level, discover_packages, SemverWorker

include("testutils.jl")

@testset "SemverChecker" begin

@testset "semver arithmetic" begin
    @test bump_version(v"1.2.3", Major) == v"2.0.0"
    @test bump_version(v"1.2.3", Minor) == v"1.3.0"
    @test bump_version(v"1.2.3", Patch) == v"1.2.4"
    @test bump_version(v"1.2.3", NoChange) == v"1.2.3"

    # 0.x.y: `x` is the breaking component, as Pkg's resolver treats it.
    @test bump_version(v"0.4.2", Major) == v"0.5.0"
    @test bump_version(v"0.4.2", Minor) == v"0.4.3"
    @test bump_version(v"0.4.2", Patch) == v"0.4.3"
    @test bump_version(v"0.0.7", Major) == v"0.0.8"
    @test bump_version(v"0.0.7", Minor) == v"0.0.8"

    @test is_sufficient(v"1.2.3", v"1.3.0", Minor)
    @test is_sufficient(v"1.2.3", v"2.0.0", Minor)      # over-bumping is fine
    @test !is_sufficient(v"1.2.3", v"1.2.4", Minor)
    @test !is_sufficient(v"1.2.3", v"1.2.3", Patch)
    @test is_sufficient(v"1.2.3", v"1.2.3", NoChange)
    @test !is_sufficient(v"0.4.2", v"0.4.3", Major)
    @test is_sufficient(v"0.4.2", v"0.5.0", Major)

    # The conventional `-DEV` marker counts as the release it precedes.
    @test is_sufficient(v"1.2.3", v"1.3.0-DEV", Minor)
    @test !is_sufficient(v"1.2.3", v"1.3.0-DEV", Minor; allow_prerelease=false)

    @test overall_level(Change[], false) == NoChange
    @test overall_level(Change[], true) == Patch
end

@testset "real subtyping" begin
    # The point of loading rather than parsing: widening an argument is not a
    # breaking change, and only Julia's own subtyping knows Int <: Integer.
    ch = apidiff(:(export f; f(x::Int) = x), :(export f; f(x::Integer) = x))
    @test !haskind(ch, "method_removed")
    @test haskind(ch, "method_added")
    @test worst(ch) == "minor"

    # Narrowing is breaking, symmetrically.
    ch = apidiff(:(export f; f(x::Integer) = x), :(export f; f(x::Int) = x))
    @test haskind(ch, "method_removed")
    @test worst(ch) == "major"

    # Widening to a Union, and to Any.
    ch = apidiff(:(export f; f(x::Int) = x), :(export f; f(x::Union{Int,String}) = x))
    @test !haskind(ch, "method_removed")
    ch = apidiff(:(export f; f(x::Int) = x), :(export f; f(x) = x))
    @test !haskind(ch, "method_removed")

    # An abstract supertype that still holds is not a break, even though the
    # declared supertype changed: DenseVector <: AbstractVector.
    ch = apidiff(:(export S; struct S <: AbstractVector{Int} end),
                 :(export S; struct S <: DenseVector{Int} end))
    @test !haskind(ch, "supertype_changed")

    # One that no longer holds is.
    ch = apidiff(:(export S; struct S <: AbstractVector{Int} end),
                 :(export S; struct S <: AbstractDict{Int,Int} end))
    @test haskind(ch, "supertype_changed")

    # Renaming a type parameter is not a change at all.
    ch = apidiff(:(export f; f(x::T) where {T<:Integer} = x),
                 :(export f; f(x::S) where {S<:Integer} = x))
    @test isempty(ch)
end

@testset "major changes" begin
    ch = apidiff(:(export f, g; f(x) = x; g(x) = x), :(export f; f(x) = x))
    @test haskind(ch, "export_removed") && worst(ch) == "major"

    ch = apidiff(:(export f; f(x::Int) = x; f(x::String) = x), :(export f; f(x::Int) = x))
    @test haskind(ch, "method_removed")

    # A type named by a released signature no longer exists at all.
    ch = apidiff(:(export f, T; struct T end; f(x::T) = x),
                 :(export f; f(x::Int) = x))
    @test haskind(ch, "signature_unresolvable")

    ch = apidiff(:(export S; struct S; a::Int; b::Int; end),
                 :(export S; struct S; a::Int; end))
    @test haskind(ch, "field_removed")

    ch = apidiff(:(export S; struct S; a::Int; end),
                 :(export S; struct S; a::Int; b::Int; end))
    @test haskind(ch, "field_added")

    ch = apidiff(:(export S; struct S; a::Int; b::Int; end),
                 :(export S; struct S; b::Int; a::Int; end))
    @test haskind(ch, "fields_reordered")

    ch = apidiff(:(export S; struct S; a::Int; end),
                 :(export S; struct S; a::Float64; end))
    @test haskind(ch, "field_type_changed")

    # The report says which direction a field moved.
    ch = apidiff(:(export S; struct S; a::Int; end),
                 :(export S; struct S; a::Union{Nothing,Int}; end))
    @test occursin("widened", detail(ch, "field_type_changed"))

    ch = apidiff(:(export S; struct S; a::Int; end),
                 :(export S; mutable struct S; a::Int; end))
    @test haskind(ch, "mutability_changed")

    ch = apidiff(:(export S; struct S{T}; a::T; end),
                 :(export S; struct S{T,U}; a::T; end))
    @test haskind(ch, "type_params_changed")

    ch = apidiff(:(export f; f(x; a=1) = x), :(export f; f(x) = x))
    @test haskind(ch, "kwarg_removed")

    ch = apidiff(:(export C; const C = 1), :(export C; const C = "s"))
    @test haskind(ch, "const_type_changed")

    # A function that became a type.
    ch = apidiff(:(export D; D(x) = x), :(export D; struct D; x::Int; end))
    @test haskind(ch, "kind_changed")

    # A union alias that narrowed.
    ch = apidiff(:(export U; const U = Union{Int,String}),
                 :(export U; const U = Union{Int,Float64}))
    @test haskind(ch, "union_changed") && worst(ch) == "major"

    # Collapsing a union to a concrete type is a change of form.
    ch = apidiff(:(export U; const U = Union{Int,String}), :(export U; const U = Int))
    @test haskind(ch, "type_form_changed") && worst(ch) == "major"
end

@testset "minor changes" begin
    ch = apidiff(:(export f; f(x) = x), :(export f, g; f(x) = x; g(x) = x))
    @test haskind(ch, "export_added") && worst(ch) == "minor"

    ch = apidiff(:(export f; f(x::Int) = x), :(export f; f(x::Int) = x; f(x::String) = x))
    @test haskind(ch, "method_added") && worst(ch) == "minor"

    ch = apidiff(:(export f; f(x) = x), :(export f; f(x; a=1) = x))
    @test haskind(ch, "kwarg_added") && worst(ch) == "minor"

    # A union alias that only grew still accepts everything it used to.
    ch = apidiff(:(export U; const U = Union{Int,String}),
                 :(export U; const U = Union{Int,String,Float64}))
    @test haskind(ch, "union_widened") && worst(ch) == "minor"

    # An added default argument keeps every old arity.
    ch = apidiff(:(export f; f(x) = x), :(export f; f(x, y=1) = x))
    @test !haskind(ch, "method_removed") && worst(ch) == "minor"
end

@testset "no public change" begin
    body = :(export f; f(x) = x; internal(y) = y)
    @test isempty(apidiff(body, body))

    # Internal churn is invisible.
    @test isempty(apidiff(:(export f; f(x) = x; hidden(y) = y),
                          :(export f; f(x) = x; hidden(y) = 2y; other() = 1)))

    # An unexported type may change freely.
    @test isempty(apidiff(:(export f; struct H; a::Int; end; f(x) = x),
                          :(export f; struct H; a::Float64; b::Int; end; f(x) = x)))
end

@testset "reexported names are part of the surface" begin
    # The gap that static analysis cannot close: a name this module never
    # defines, but does export, still belongs to its API.
    ch = apidiff(:(using Test; export detect_ambiguities, f; f() = 1),
                 :(export f; f() = 1))
    @test haskind(ch, "export_removed")
    @test detail(ch, "export_removed") == "`detect_ambiguities` is no longer public"
end

@testset "public submodules" begin
    # A public submodule's exports are reachable as Package.Inner.thing.
    old = :(module Inner; export g; g(x::Int) = x; end; export Inner)
    new = :(module Inner; export g; g(x::String) = x; end; export Inner)
    ch = apidiff(old, new)
    @test any(c -> c["name"] == "Inner.g", ch)
    @test haskind(ch, "method_removed")
end

@testset "method ownership" begin
    @test SemverWorker.is_stdlib_module(Base) && SemverWorker.is_stdlib_module(Core)
    @test SemverWorker.is_stdlib_module(Base.Sys)
    @test !SemverWorker.is_stdlib_module(SemverChecker)

    # A package sees itself and anything it has bound; not unrelated modules.
    @test SemverWorker.is_visible_from(SemverChecker, SemverChecker)
    @test SemverWorker.is_visible_from(SemverChecker.SemverWorker, SemverChecker)
    @test !SemverWorker.is_visible_from(Test, SemverChecker)

    # Extending a Base function is the package's own API; Base's own methods
    # for it are not.
    ch = apidiff(:(export mysize; Base.size(x::Int, y::Int) = 0; mysize() = 1),
                 :(export mysize; mysize() = 1))
    @test !haskind(ch, "method_removed")   # `size` was never exported here
end

@testset "signature rendering" begin
    p = SemverWorker._pretty
    @test p("Tuple{typeof(Foo.bar), Core.Int64, Core.String}") == "Foo.bar(Int64, String)"
    @test p("Tuple{typeof(Foo.g)}") == "Foo.g()"
    @test p("Tuple{typeof(Foo.f), Base.Vector{T}} where T<:Core.Real") ==
          "Foo.f(Vector{T}) where T<:Real"
    @test p("Union{Nothing, M.SHA1Hash}") == "Union{Nothing, M.SHA1Hash}"
end

@testset "source hashing" begin
    uuid = "11111111-1111-1111-1111-111111111111"
    d1, d2 = mktempdir(), mktempdir()
    a = make_pkg(d1, "H", "f() = 1"; uuid, version="1.0.0")
    b = make_pkg(d2, "H", "f() = 1"; uuid, version="9.9.9")
    # Identical sources differing only in `version` hash the same: bumping the
    # version must not by itself make a package look changed.
    @test SemverWorker.source_hash(a) == SemverWorker.source_hash(b)

    write(joinpath(b, "src", "H.jl"), "module H\nf() = 2\nend\n")
    @test SemverWorker.source_hash(a) != SemverWorker.source_hash(b)

    # Compat bounds are part of the package, so changing them does count.
    write(joinpath(b, "src", "H.jl"), "module H\nf() = 1\nend\n")
    @test SemverWorker.source_hash(a) == SemverWorker.source_hash(b)
    open(joinpath(b, "Project.toml"), "a") do io
        println(io, "\n[compat]\njulia = \"1.10\"")
    end
    @test SemverWorker.source_hash(a) != SemverWorker.source_hash(b)
end

@testset "discovery" begin
    dir = mktempdir()
    make_pkg(dir, "A", "export a; a() = 1")
    make_pkg(joinpath(dir, "nested"), "B", "export b; b() = 1")
    # A test environment is a project but not a package, and must be ignored.
    mkpath(joinpath(dir, "A", "test"))
    write(joinpath(dir, "A", "test", "Project.toml"), "[deps]\n")
    mkpath(joinpath(dir, "docs"))
    write(joinpath(dir, "docs", "Project.toml"), "[deps]\n")

    found = discover_packages(dir)
    @test length(found) == 2
    @test Set(basename.(found)) == Set(["A", "B"])
end

@testset "reporting" begin
    rv = SemverChecker.RegisteredVersion("Demo", UUIDs.uuid4(), v"1.0.0", "General")
    reports = [SemverChecker.PackageReport(
        "Demo", "Demo", v"1.0.0", rv, Major,
        [Change(Major, :export_removed, :gone, "`gone` is no longer public", "src/Demo.jl:3")],
        v"2.0.0", :needs_bump, "", String[])]

    text = sprint(io -> SemverChecker.print_report(io, reports))
    @test occursin("bump version to at least 2.0.0", text)
    @test occursin("no longer public", text)

    gha = sprint(io -> SemverChecker.print_github_annotations(io, reports))
    @test startswith(gha, "::error file=Demo/Project.toml,line=")
    @test occursin("%0A", gha)             # newlines are escaped for the runner

    md = sprint(io -> SemverChecker.print_markdown(io, reports))
    @test occursin("| `Demo` |", md) && occursin("**≥ 2.0.0**", md)

    json = sprint(io -> SemverChecker.print_json(io, reports))
    @test occursin("\"ok\":false", json) && occursin("\"minimum_version\":\"2.0.0\"", json)
end

@testset "apply_bumps!" begin
    dir = mktempdir()
    root = make_pkg(dir, "Fix", "export f; f() = 1"; version="1.0.0")
    reports = [SemverChecker.PackageReport(
        "Fix", "Fix", v"1.0.0", nothing, Minor, Change[],
        v"1.1.0", :needs_bump, "", String[])]
    @test length(SemverChecker.apply_bumps!(reports; root=dir)) == 1
    @test occursin("version = \"1.1.0\"", read(joinpath(root, "Project.toml"), String))
end

@testset "cli" begin
    @test SemverChecker.main(["--help"]) == 0
    @test SemverChecker.main(["--nonsense"]) == 2
end

# The full two-subprocess path needs a registry and a package server.
if get(ENV, "SEMVERCHECKER_INTEGRATION", "") == "true"
    @testset "end to end" begin
        reports = SemverChecker.check(dirname(@__DIR__))
        @test length(reports) == 1
        @test reports[1].name == "SemverChecker"
    end
end

end # testset
