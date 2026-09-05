# Helpers for building throwaway packages on disk to analyze.

"""
    make_pkg(dir, name, body; version="1.0.0", uuid=..., files=Dict())

Write a minimal package into `dir/name` whose entry point contains `body`
wrapped in a module.  Extra `files` are written relative to the package root.
"""
function make_pkg(dir, name, body; version="1.0.0", uuid=string(UUIDs.uuid4()),
                  files::Dict{String,String}=Dict{String,String}())
    root = joinpath(dir, name)
    mkpath(joinpath(root, "src"))
    write(joinpath(root, "Project.toml"), """
        name = "$(name)"
        uuid = "$(uuid)"
        version = "$(version)"
        """)
    write(joinpath(root, "src", "$(name).jl"), "module $(name)\n$(body)\nend\n")
    for (p, contents) in files
        mkpath(dirname(joinpath(root, p)))
        write(joinpath(root, p), contents)
    end
    return root
end

"""
    surfaces(old_body, new_body) -> (old, new)

Extract surfaces for two versions of the same package body.
"""
function surfaces(old_body, new_body; name="Fixture")
    dir = mktempdir()
    uuid = string(UUIDs.uuid4())   # the same package, so the same UUID
    o = SemverChecker.extract_surface(make_pkg(joinpath(dir, "old"), name, old_body; uuid))
    n = SemverChecker.extract_surface(make_pkg(joinpath(dir, "new"), name, new_body; uuid))
    return o, n
end

"""
    diff_level(old_body, new_body) -> (BumpLevel, changes)

The verdict `compare_surfaces` reaches for two package bodies.
"""
function diff_level(old_body, new_body)
    o, n = surfaces(old_body, new_body)
    changes = SemverChecker.compare_surfaces(o, n)
    touched = o.source_hash != n.source_hash
    return SemverChecker.overall_level(changes, touched), changes
end

has_kind(changes, kind) = any(c -> c.kind === kind, changes)
