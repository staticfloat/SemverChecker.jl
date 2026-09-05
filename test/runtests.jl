using Test, UUIDs
using SemverChecker
using SemverChecker: NoChange, Patch, Minor, Major, bump_version, is_sufficient,
                     type_covers, covers, ConcreteSig, MethodSig, ArgSpec,
                     expand_arities, normalize_type, compare_surfaces,
                     extract_surface, discover_packages, public_names

include("testutils.jl")

@testset "SemverChecker" begin

@testset "semver arithmetic" begin
    # Post-1.0: the ordinary rules.
    @test bump_version(v"1.2.3", Major) == v"2.0.0"
    @test bump_version(v"1.2.3", Minor) == v"1.3.0"
    @test bump_version(v"1.2.3", Patch) == v"1.2.4"
    @test bump_version(v"1.2.3", NoChange) == v"1.2.3"

    # 0.x.y: `x` is the breaking component, as Pkg's resolver treats it.
    @test bump_version(v"0.4.2", Major) == v"0.5.0"
    @test bump_version(v"0.4.2", Minor) == v"0.4.3"
    @test bump_version(v"0.4.2", Patch) == v"0.4.3"

    # 0.0.z: everything is potentially breaking.
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
end

@testset "type widening" begin
    @test type_covers("Int", "Int")
    @test type_covers("Any", "Int")
    @test !type_covers("Int", "Any")
    @test !type_covers("Int", "Integer")
    @test type_covers("Union{Int,String}", "Int")
    @test type_covers("Union{Int, String}", "String")
    @test !type_covers("Union{Int,String}", "Float64")
    @test type_covers("Union{Int,Union{String,Bool}}", "Bool")
end

@testset "signature coverage" begin
    sig(ts...; va=nothing) = ConcreteSig(String[ts...], va)
    @test covers(sig("Int"), sig("Int"))
    @test covers(sig("Any"), sig("Int"))
    @test !covers(sig("Int"), sig("Any"))
    @test !covers(sig("Int", "Int"), sig("Int"))          # arity mismatch
    @test covers(sig("Int"; va="Any"), sig("Int", "Bool")) # vararg absorbs extras
    @test covers(sig(; va="Any"), sig("Int", "Bool"))
    @test !covers(sig("Int"; va="Int"), sig("Int", "String"))
end

@testset "arity expansion" begin
    m = MethodSig([ArgSpec("Int", false, false), ArgSpec("Bool", true, false)],
                  SemverChecker.KwSpec[], "f.jl", 1)
    sigs = expand_arities(m)
    @test length(sigs) == 2
    @test sigs[1].types == ["Int"]
    @test sigs[2].types == ["Int", "Bool"]

    v = MethodSig([ArgSpec("Int", false, false), ArgSpec("Any", false, true)],
                  SemverChecker.KwSpec[], "f.jl", 1)
    @test expand_arities(v)[end].vararg == "Any"
end

@testset "type normalization" begin
    @test normalize_type(:Int) == "Int"
    @test normalize_type(:(Vector{Int})) == "Vector{Int}"
    # `where` type variables are replaced by their bounds so that renaming a
    # type variable does not read as an API change.
    o, n = surfaces("export f\nf(x::T) where {T<:Integer} = x",
                    "export f\nf(x::S) where {S<:Integer} = x")
    @test isempty(compare_surfaces(o, n))
end

@testset "extraction" begin
    dir = mktempdir()
    root = make_pkg(dir, "Ext", """
        export foo, Bar, Baz, QUX, @mac
        public helper

        abstract type Baz end
        struct Bar{T<:Real} <: Baz
            a::Int
            b::Vector{T}
        end
        Base.@kwdef struct Unexported
            x::Int = 1
        end
        const QUX = 42
        foo(x::Int, y::String="s"; z::Bool=false) = x
        function foo(x::Float64) end
        helper() = nothing
        macro mac(x) end
        @enum Color red green
        include("more.jl")
        """; files = Dict("src/more.jl" => "included_fn(x::Symbol) = x\nexport included_fn\n"))
    s = extract_surface(root)

    @test s.name == "Ext"
    @test s.version == v"1.0.0"
    @test :foo in s.exports && :Bar in s.exports && Symbol("@mac") in s.exports
    @test :helper in s.publics
    @test :included_fn in s.exports          # `include` was followed
    @test haskey(s.functions, :included_fn)

    @test s.types[:Bar].kind === :struct
    @test s.types[:Bar].supertype == "Baz"
    @test s.types[:Bar].params == ["Real"]
    @test s.types[:Bar].fields == [(:a, "Int"), (:b, "Vector{Real}")]
    @test s.types[:Baz].kind === :abstract
    @test s.types[:Unexported].fields == [(:x, "Int")]   # @kwdef default stripped

    @test length(s.functions[:foo]) == 2
    @test haskey(s.macros, Symbol("@mac"))
    @test s.consts[:QUX].name == :QUX
    @test haskey(s.types, :Color) && haskey(s.consts, :red)
    @test isempty(s.parse_errors)
end

@testset "major changes" begin
    # An exported name disappears.
    lvl, ch = diff_level("export f, g\nf(x) = x\ng(x) = x", "export f\nf(x) = x")
    @test lvl == Major && has_kind(ch, :export_removed)

    # An argument type narrows.
    lvl, ch = diff_level("export f\nf(x) = x", "export f\nf(x::Int) = x")
    @test lvl == Major && has_kind(ch, :method_removed)

    # A method is dropped entirely.
    lvl, ch = diff_level("export f\nf(x::Int) = x\nf(x::String) = x", "export f\nf(x::Int) = x")
    @test lvl == Major && has_kind(ch, :method_removed)

    # Struct layout changes.
    lvl, ch = diff_level("export S\nstruct S\n a::Int\n b::Int\nend",
                         "export S\nstruct S\n a::Int\nend")
    @test lvl == Major && has_kind(ch, :field_removed)

    lvl, ch = diff_level("export S\nstruct S\n a::Int\nend",
                         "export S\nstruct S\n a::Int\n b::Int\nend")
    @test lvl == Major && has_kind(ch, :field_added)

    lvl, ch = diff_level("export S\nstruct S\n a::Int\nend",
                         "export S\nstruct S\n a::Float64\nend")
    @test lvl == Major && has_kind(ch, :field_type_changed)

    lvl, ch = diff_level("export S\nstruct S\n a::Int\n b::Int\nend",
                         "export S\nstruct S\n b::Int\n a::Int\nend")
    @test lvl == Major && has_kind(ch, :fields_reordered)

    lvl, ch = diff_level("export S\nstruct S\n a::Int\nend",
                         "export S\nmutable struct S\n a::Int\nend")
    @test lvl == Major && has_kind(ch, :mutability_changed)

    lvl, ch = diff_level("export S\nabstract type P end\nstruct S <: P\n a::Int\nend",
                         "export S\nabstract type P end\nstruct S\n a::Int\nend")
    @test lvl == Major && has_kind(ch, :supertype_changed)

    # A const becomes a type.
    lvl, ch = diff_level("export D\nconst D = Int", "export D\nstruct D\n x::Int\nend")
    @test lvl == Major && has_kind(ch, :kind_changed)

    # Keyword arguments.
    lvl, ch = diff_level("export f\nf(x; a=1) = x", "export f\nf(x) = x")
    @test lvl == Major && has_kind(ch, :kwarg_removed)

    lvl, ch = diff_level("export f\nf(x) = x", "export f\nf(x; a) = x")
    @test lvl == Major && has_kind(ch, :kwarg_added)

    lvl, ch = diff_level("export f\nf(x; a=1) = x", "export f\nf(x; a) = x")
    @test lvl == Major && has_kind(ch, :kwarg_required)
end

@testset "minor changes" begin
    # A newly exported name.
    lvl, ch = diff_level("export f\nf(x) = x", "export f, g\nf(x) = x\ng(x) = x")
    @test lvl == Minor && has_kind(ch, :export_added)

    # A new method on an existing exported function.
    lvl, ch = diff_level("export f\nf(x::Int) = x", "export f\nf(x::Int) = x\nf(x::String) = x")
    @test lvl == Minor && has_kind(ch, :method_added)

    # A new optional keyword argument.
    lvl, ch = diff_level("export f\nf(x) = x", "export f\nf(x; a=1) = x")
    @test lvl == Minor && has_kind(ch, :kwarg_added)

    # A new type.
    lvl, ch = diff_level("export S\nstruct S end", "export S, T\nstruct S end\nstruct T end")
    @test lvl == Minor

    # A new method is reported at the line it is written on, not at the first
    # method of the function.
    lvl, ch = diff_level("export f\nf(x::Int) = x",
                         "export f\nf(x::Int) = x\n\n\nf(x::String) = x")
    added = only(filter(c -> c.kind === :method_added, ch))
    @test added.location == "src/Fixture.jl:6"
end

@testset "patch and no change" begin
    # Internals moved around; the exported surface is identical.
    lvl, ch = diff_level("export f\nf(x) = x\ninternal(y) = y",
                         "export f\nf(x) = x\ninternal(y) = 2y")
    @test lvl == Patch && isempty(ch)

    # A new *unexported* function is still only a patch.
    lvl, ch = diff_level("export f\nf(x) = x", "export f\nf(x) = x\nhidden(y) = y")
    @test lvl == Patch && isempty(ch)

    # Byte-identical source needs no bump at all.
    o, n = surfaces("export f\nf(x) = x", "export f\nf(x) = x")
    @test o.source_hash == n.source_hash
    @test SemverChecker.overall_level(compare_surfaces(o, n), false) == NoChange
end

@testset "widening is not breaking" begin
    # Loosening an argument type keeps every old call working.
    lvl, ch = diff_level("export f\nf(x::Int) = x", "export f\nf(x) = x")
    @test lvl == Minor          # strictly more calls accepted: a new method
    @test !has_kind(ch, :method_removed)

    lvl, ch = diff_level("export f\nf(x::Int) = x", "export f\nf(x::Union{Int,String}) = x")
    @test !has_kind(ch, :method_removed)

    # Adding a defaulted positional argument keeps the old arity.
    lvl, ch = diff_level("export f\nf(x) = x", "export f\nf(x, y=1) = x")
    @test lvl == Minor && !has_kind(ch, :method_removed)
end

@testset "internal churn is invisible" begin
    # Unexported types may change freely.
    lvl, ch = diff_level("struct Hidden\n a::Int\nend", "struct Hidden\n a::Float64\n b::Int\nend")
    @test lvl == Patch && isempty(ch)
end

@testset "discovery" begin
    dir = mktempdir()
    make_pkg(dir, "A", "export a\na() = 1")
    make_pkg(joinpath(dir, "nested"), "B", "export b\nb() = 1")
    # A test environment is a project but not a package, and must be ignored.
    mkpath(joinpath(dir, "A", "test"))
    write(joinpath(dir, "A", "test", "Project.toml"), "[deps]\n")
    # A docs environment likewise.
    mkpath(joinpath(dir, "docs"))
    write(joinpath(dir, "docs", "Project.toml"), "[deps]\n")

    found = discover_packages(dir)
    @test length(found) == 2
    @test Set(basename.(found)) == Set(["A", "B"])
end

@testset "reporting" begin
    reports = [SemverChecker.PackageReport(
        "Demo", "Demo", v"1.0.0",
        SemverChecker.RegisteredVersion("Demo", UUIDs.uuid4(), v"1.0.0", "abc", "General", nothing, nothing),
        Major,
        [SemverChecker.Change(Major, :export_removed, :gone, "`gone` is no longer exported", "src/Demo.jl:3")],
        v"2.0.0", :needs_bump, "", String[])]

    text = sprint(io -> SemverChecker.print_report(io, reports))
    @test occursin("bump version to at least 2.0.0", text)
    @test occursin("no longer exported", text)

    gha = sprint(io -> SemverChecker.print_github_annotations(io, reports))
    @test startswith(gha, "::error file=Demo/Project.toml,line=")
    @test occursin("%0A", gha)             # newlines are escaped for the runner

    md = sprint(io -> SemverChecker.print_markdown(io, reports))
    @test occursin("| `Demo` |", md)
    @test occursin("**≥ 2.0.0**", md)

    json = sprint(io -> SemverChecker.print_json(io, reports))
    @test occursin("\"ok\":false", json)
    @test occursin("\"minimum_version\":\"2.0.0\"", json)
end

@testset "reports for unusual packages" begin
    dir = mktempdir()
    # No `version` field at all.
    root = make_pkg(dir, "NoVer", "export f\nf() = 1")
    write(joinpath(root, "Project.toml"),
          "name = \"NoVer\"\nuuid = \"$(UUIDs.uuid4())\"\n")
    r = SemverChecker.check_package(root)
    @test r.status === :no_version

    # A package with a UUID nobody has registered.
    root2 = make_pkg(dir, "DefinitelyNotRegistered$(rand(UInt32))", "export f\nf() = 1")
    r2 = SemverChecker.check_package(root2)
    @test r2.status === :unregistered
end

@testset "apply_bumps!" begin
    dir = mktempdir()
    root = make_pkg(dir, "Fix", "export f\nf() = 1"; version="1.0.0")
    reports = [SemverChecker.PackageReport(
        "Fix", "Fix", v"1.0.0", nothing, Minor, SemverChecker.Change[],
        v"1.1.0", :needs_bump, "", String[])]
    changed = SemverChecker.apply_bumps!(reports; root=dir)
    @test length(changed) == 1
    @test occursin("version = \"1.1.0\"", read(joinpath(root, "Project.toml"), String))
end

@testset "cli" begin
    @test SemverChecker.main(["--help"]) == 0
    @test SemverChecker.main(["--nonsense"]) == 2

    dir = mktempdir()
    make_pkg(dir, "CliDemo$(rand(UInt32))", "export f\nf() = 1")
    # Unregistered packages must not fail the build.
    @test SemverChecker.main(["--format=json", dir]) == 0
end

end # testset
