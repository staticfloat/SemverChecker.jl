"""
    SemverChecker

Compare the packages in a repository against their latest registered releases
and report how far each package's version needs to be bumped.

The check is a *reminder*, meant to run in CI while a change is still in review:

  - **major** — a previously public name disappeared, a method no longer accepts
    arguments it used to, or an exported type's layout changed;
  - **minor** — new public names or new methods on existing public functions;
  - **patch** — the source changed but the public surface did not;
  - **none**  — nothing changed since the release, so no bump is needed.

Nothing is loaded or executed: surfaces are recovered by parsing the source, so
the check works on the released tarball as well as the working tree, and needs
no dependency resolution.

# Example

```julia
using SemverChecker
reports = SemverChecker.check("path/to/repo")
SemverChecker.print_report(stdout, reports)
```

See also [`check`](@ref), [`check_package`](@ref), [`main`](@ref).
"""
module SemverChecker

using TOML, SHA, Downloads, Tar, Pkg, UUIDs
using CodecZlib: GzipDecompressorStream

export check, check_package, print_report

include("surface.jl")
include("extract.jl")
include("registry.jl")
include("compare.jl")
include("check.jl")
include("report.jl")
include("cli.jl")

end # module
