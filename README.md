# SemverChecker.jl

A CI reminder to bump your version.

SemverChecker scans a repository — including monorepos holding many packages —
compares each package against its **latest registered release**, and tells you
how far the version in `Project.toml` needs to be bumped:

| Verdict   | What it means                                                                   |
|-----------|---------------------------------------------------------------------------------|
| **major** | A public name disappeared, or a method or constructor no longer accepts arguments it used to. |
| **minor** | New public names, new methods, new keyword arguments, or a widened union.        |
| **patch** | The source changed but the public surface did not.                              |
| *none*    | Nothing changed since the release. No bump needed; nothing is reported.          |

If the version has *already* been bumped far enough, the check passes silently.
The goal is to nudge during development, not to nag.

## How it works

SemverChecker **loads** both the released version and your working tree, in two
subprocesses, and compares their API surfaces using **real Julia dispatch**.

Two versions of a package cannot coexist in one session, so each side gets its
own process. Every package in the repository is resolved into a *single*
environment per side, so a thirteen-package monorepo costs two loads in total,
not twenty-six.

Signatures are recorded fully qualified (`Tuple{typeof(Foo.bar),
Core.Int64}`), which makes them re-evaluable in the other process. The question
"is this still a breaking change?" then becomes a question Julia itself
answers:

```julia
S_old = Core.eval(scope, :(Tuple{typeof(Foo.bar), Core.Int64}))
any(m -> S_old <: m.sig, methods(Foo.bar))   # still dispatched?
```

Because this is the real dispatch rule, widening is recognised without any
special-casing: `f(::Int)` → `f(::Integer)` is not a break, `f(::Integer)` →
`f(::Int)` is, and no table of hand-written subtyping rules is involved.

Loading rather than parsing buys three things that reading source cannot:

- **Reexports are visible.** `names(M)` is the real answer. BinaryBuilder2
  exports 117 names, of which only 30 are defined in BinaryBuilder2 itself; the
  rest are reexported from sibling packages. Across that monorepo, 352 names are
  exported and only 140 are defined in their own package — **60% of the public
  API is reexported**, and every bit of it is invisible to source analysis.
- **Generated code is visible.** Methods and types produced by `@eval` loops,
  `@kwdef`, `@enum` or any other macro are simply there in the method table.
- **Aliases are resolved.** `const HashOrString = Union{String,MultiHash}`
  is compared as the union it denotes, not as the seven characters of its name.

## Which conventions this follows

The rules are not invented here; they are the ones the Julia community has
written down, and each is verifiable:

- **Version arithmetic** follows [ColPrac](https://github.com/SciML/ColPrac)
  verbatim — "Post-1.0.0: for breaking changes increment X, for non-breaking new
  features increment Y, for bug-fixes increment Z. Pre-1.0.0: for breaking
  changes increment Y, for non-breaking (feature or bug-fix) increment Z." Below
  `1.0`, features and fixes therefore share the patch digit, and `0.0.z` treats
  every change as breaking — matching
  [Pkg's compat rules](https://pkgdocs.julialang.org/v1/compatibility/), where
  `^0.4.2` means `[0.4.2, 0.5.0)` and `^0.0.3` means `[0.0.3, 0.0.4)`.
- **Public API** means names that are exported or declared `public`, which is
  ColPrac's own definition.
- **Adding an export is never breaking**, per ColPrac; it is reported as a
  feature.
- **Adding a supertype in a hierarchy is not breaking.** A supertype change is
  only reported when the type no longer satisfies the old one, which is a real
  `<:` check rather than a comparison of names.
- **Introducing a deprecation is not breaking; removing one is.** This falls out
  of the method comparison without a special case.
- **Struct fields are not compared.** Julia convention treats a struct's fields
  and their types as an implementation detail — `propertynames` is the
  documented interface — so diffing the layout would report private churn as a
  breaking change. What callers depend on is the *constructor*, so that is what
  is compared. A layout change that does reach callers still surfaces there:
  adding a field to a struct with the generated constructor turns `S(a, b)` into
  `S(a, b, c)`, while adding one behind an explicit inner constructor correctly
  changes nothing.

The check also warns when a version is bumped *far enough but not by a standard
increment*. [RegistryCI's AutoMerge](https://juliaregistries.github.io/RegistryCI.jl/stable/guidelines/)
requires "a standard increment and not skip versions", so `1.2.3` → `1.5.0` is
rejected at registration even though it clearly covers a minor change. That is a
note, not a failure — the version is not too low.

## Installation

```julia
pkg> add SemverChecker
```

## Command line

```console
$ julia -e 'using SemverChecker; exit(SemverChecker.main())' -- .
✗ BinaryBuilder2: bump version to at least 2.0.0 (currently 1.0.1, released 1.0.1, detected major change)
    [major] `BuildResult.log_artifact` type changed: `MultiHashParsing.SHA1Hash` → `Union{Nothing, MultiHashParsing.SHA1Hash}` (widened)
    [major] `BuildMeta` lost field `json_output::Union{Nothing, IO}`
    [major] `BuildMeta` gained field `archive_dir::Union{Nothing, String}` (changes the layout and the default constructor)
✓ BinaryBuilderGitUtils: unchanged since v0.2.0
✗ ScratchSpaceGarbageCollector: bump version to at least 0.1.2 (currently 0.1.1, released 0.1.1, detected patch change)

3 of 13 package(s) need a version bump.
```

Exit status is `1` when at least one package needs a bump, `0` otherwise.

### Options

| Option | Effect |
|---|---|
| `--path=DIR` | Repository to scan (default `.`; also accepted positionally) |
| `--package=DIR` | Check only this package directory; repeatable |
| `--format=FMT` | `auto`, `text`, `github`, `markdown`, `json` |
| `--summary` | Append a Markdown report to `$GITHUB_STEP_SUMMARY` |
| `--fix` | Rewrite `Project.toml` versions to the minimum acceptable |
| `--logdir=DIR` | Keep the subprocess logs here (default: a temporary directory) |
| `--skip=NAME` | Directory name to skip during discovery; repeatable |
| `--no-prerelease` | Do not treat `1.2.0-DEV` as satisfying a bump to `1.2.0` |
| `--verbose` | Also show packages that are already fine |
| `--exit-zero` | Always exit `0` (report only, never fail the build) |

`--format=auto` picks `github` when `$GITHUB_ACTIONS` is set and `text`
otherwise.

## Julia API

```julia
using SemverChecker

reports = check("path/to/repo")          # Vector{PackageReport}
print_report(stdout, reports; verbose=true)

for r in reports
    r.status === :needs_bump || continue
    @info "$(r.name) needs $(r.level)" required = r.minimum_version
    for c in r.changes
        println("  ", c.level, ": ", c.detail, "  @ ", c.location)
    end
end
```

Each `PackageReport` has a `status` of `:ok`, `:needs_bump`, `:unregistered`
(nothing to compare against), `:no_version`, or `:error`.

## What this costs

The released versions have to be installed and both sides have to be loaded.
Measured on BinaryBuilder2's thirteen packages:

| | released side | working tree |
|---|---|---|
| Warm depot | ~3s | ~1s |
| Cold depot | ~155s, 2.6GB | ~46s |

The whole check is ~15s on a warm depot. A cold depot is the honest worst case,
and BinaryBuilder2 is unusually heavy — it pulls JLL binary artifacts. In CI,
`julia-actions/cache@v2` keeps the depot warm, and the test job already pays the
cost of loading the working tree.

## Requirements and limitations

The check needs to actually load your code, which implies:

- **Both sides must resolve and load.** If the released version or the working
  tree cannot be installed or loaded, that package reports `:error` with the
  reason rather than a verdict. Other packages are unaffected. If the whole set
  cannot resolve together, SemverChecker retries one environment per package.
- **Package code runs.** `__init__` and precompilation execute, as they do for
  your test job. Output is captured into the subprocess logs (`--logdir`) rather
  than interleaved with the report.
- **A registry and the released source are needed**, so CI must be able to reach
  its package server.

Two things are deliberately out of reach:

- **Required vs optional keyword arguments.** The method table records keyword
  *names* but not their defaults, so a newly *required* keyword is reported as
  `minor`, not `major`. ColPrac would call that breaking.
- **Methods from modules the package cannot see.** A generic function is shared
  by everyone who extends it, so `methods(f)` includes methods from unrelated
  co-loaded packages. Only methods defined by the package itself or by something
  it has bound (`using Foo` — which is what makes reexports work) count as its
  surface.

One more thing is excluded on purpose. Julia generates *two* constructors for a
struct with typed fields — `S(::Int)` and `S(::Any)`, the latter calling
`convert` — and the untyped one accepts anything. Counting it would make the
whole question vacuous: a deleted `S(::String)` would still look reachable,
because `S(::Any)` swallows the call and only then fails inside `convert`. It is
identified by shape (all-`Any` arguments, one per field, sharing a source line
with a sibling that spells the field types out) and left out of the comparison.
A hand-written untyped constructor lives on its own line and is kept.

## Prerelease versions

The Julia convention of marking in-development versions as `1.3.0-DEV` is
honoured by default: the suffix is ignored when checking whether the bump is
large enough, so `1.3.0-DEV` satisfies a required minor bump to `1.3.0`. Pass
`--no-prerelease` for strict comparison.

## Versions below 1.0

Pkg's resolver treats the leading non-zero component of a `0.x.y` version as the
breaking one, and SemverChecker follows suit:

| Released | Change  | Minimum acceptable |
|---|---|---|
| `1.2.3` | major | `2.0.0` |
| `1.2.3` | minor | `1.3.0` |
| `1.2.3` | patch | `1.2.4` |
| `0.4.2` | major | `0.5.0` |
| `0.4.2` | minor | `0.4.3` |
| `0.0.7` | *any*  | `0.0.8` |

## Documentation

- [Using SemverChecker in CI](docs/src/ci.md) — GitHub Actions, GitLab CI,
  Buildkite, and pre-push hooks.

## License

MIT.
