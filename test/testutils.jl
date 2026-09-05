# Helpers for exercising the comparison rules in-process.

const _FIXTURE_N = Ref(0)

function _mkmod(name::Symbol, body::Expr)
    # Redefining a module warns on stderr; that is expected here, not a problem.
    #
    # The module object must come from `Core.eval`'s return value, not from
    # reading `Main.<name>` afterwards: under Julia 1.12's world-age rules that
    # read still sees the *previous* binding, and the comparison would silently
    # diff a module against itself.
    return redirect_stderr(devnull) do
        Core.eval(Main, Expr(:module, true, name, body))
    end
end

"""
    apidiff(old_body, new_body) -> Vector{Dict}

Define a module with `old_body`, record its surface, then redefine the *same*
module with `new_body` and compare the two.

Reusing the module name is what makes this faithful rather than a mock: the
recorded signatures name `Main.FixtureN.f`, so evaluating them after the
redefinition resolves them against the new definitions — precisely what happens
across the two subprocesses in a real run.
"""
function apidiff(old_body::Expr, new_body::Expr)
    _FIXTURE_N[] += 1
    name = Symbol("Fixture", _FIXTURE_N[])
    old = Base.invokelatest(SemverWorker.surface_of, _mkmod(name, old_body))
    return Base.invokelatest(SemverWorker.compare, old, _mkmod(name, new_body))
end

haskind(changes, kind) = any(c -> c["kind"] == kind, changes)
levels(changes) = Set(c["level"] for c in changes)
worst(changes) = isempty(changes) ? "none" :
                 ("major" in levels(changes) ? "major" : "minor")
detail(changes, kind) = something(findfirst(c -> c["kind"] == kind, changes), 0) == 0 ?
                        "" : changes[findfirst(c -> c["kind"] == kind, changes)]["detail"]

"""
    make_pkg(dir, name, body; version, uuid) -> String

Write a minimal package to disk, for discovery and Project.toml tests.
"""
function make_pkg(dir, name, body; version="1.0.0", uuid=string(UUIDs.uuid4()))
    root = joinpath(dir, name)
    mkpath(joinpath(root, "src"))
    write(joinpath(root, "Project.toml"),
          "name = \"$(name)\"\nuuid = \"$(uuid)\"\nversion = \"$(version)\"\n")
    write(joinpath(root, "src", "$(name).jl"), "module $(name)\n$(body)\nend\n")
    return root
end
