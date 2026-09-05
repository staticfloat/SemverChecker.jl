"""
    SemverChecker

Compare the packages in a repository against their latest registered releases
and report how far each package's version needs to be bumped.

The check is a *reminder*, meant to run in CI while a change is still in review:

  - **major** — a previously public name disappeared, a method no longer accepts
    arguments it used to, or a public type's layout or supertype changed;
  - **minor** — new public names, new methods, or new keyword arguments;
  - **patch** — the source changed but the public surface did not;
  - **none**  — nothing changed since the release, so no bump is needed.

Both the released version and the working tree are loaded, in two subprocesses
batched so that a whole monorepo costs two loads rather than two per package.
Surfaces are then compared with real Julia dispatch — `S_old <: method.sig` —
so the answer accounts for reexported names, methods created by code
generation, and resolved type aliases, none of which can be read off the source
text.

# Example

```julia
using SemverChecker
reports = SemverChecker.check("path/to/repo")
SemverChecker.print_report(stdout, reports)
```

See also [`check`](@ref), [`main`](@ref).
"""
module SemverChecker

using TOML, Pkg, Serialization, UUIDs

export check, print_report

include("worker.jl")        # also `include`d standalone by the subprocess
include("semver.jl")
include("registry.jl")
include("check.jl")
include("report.jl")
include("cli.jl")

end # module
