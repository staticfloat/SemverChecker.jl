# SemverChecker.jl

A CI reminder to bump your version.

SemverChecker scans a repository — including monorepos holding many packages —
compares each package against its **latest registered release**, and tells you
how far the version in `Project.toml` needs to be bumped:

| Verdict   | What it means                                                                   |
|-----------|---------------------------------------------------------------------------------|
| **major** | A public name disappeared, a method no longer accepts arguments it used to, or an exported type's layout changed. |
| **minor** | New public names, new methods on existing public functions, or new optional keyword arguments. |
| **patch** | The source changed but the public surface did not.                              |
| *none*    | Nothing changed since the release. No bump needed; nothing is reported.          |

If the version has *already* been bumped far enough, the check passes silently.
The goal is to nudge during development, not to nag.

## How it works

Both surfaces — the released one and your working tree — are recovered by
**parsing the source**. Nothing is loaded, instantiated or executed, which means:

- no dependency resolution for the old version (often impossible for old releases);
- no need for your package to even be loadable on the CI machine;
- the whole scan takes a few seconds for a dozen packages.

The released source comes from the registry's recorded tree hash, fetched from
your package server (or from an already-installed copy in the depot, for free).

Because it is static analysis, the type reasoning is deliberately conservative:
widening an argument to `Any` or growing a `Union` is recognised as
non-breaking, and anything else that changes is reported for a human to judge.
A false *major* costs you a glance at the report; a missed break costs a broken
release.

## Installation

```julia
pkg> add SemverChecker
```

## Command line

```console
$ julia -e 'using SemverChecker; exit(SemverChecker.main())' -- .
✗ BinaryBuilder2: bump version to at least 2.0.0 (currently 1.0.1, released 1.0.1, detected major change)
    [major] `Dependency` changed from a const to a type  (src/Compat.jl:13)
    [major] `BuildResult.log_artifact` type changed: `SHA1Hash` → `Union{Nothing, SHA1Hash}`  (src/build_api/BuildResult.jl:4)
    [major] `BuildMeta` lost field `json_output::Union{Nothing, IO}`  (src/build_api/BuildMeta.jl:218)
    [major] `BuildMeta` gained field `archive_dir::Union{Nothing, String}` (changes layout and the default constructor)  (src/build_api/BuildMeta.jl:218)
✓ BinaryBuilderGitUtils: unchanged since v0.2.0
✗ ScratchSpaceGarbageCollector: bump version to at least 0.1.2 (currently 0.1.1, released 0.1.1, detected patch change)

2 of 13 package(s) need a version bump.
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

`check_package(dir)` runs a single package. Each `PackageReport` has a `status`
of `:ok`, `:needs_bump`, `:unregistered` (nothing to compare against),
`:no_version`, or `:error`.

## Prerelease versions

The Julia convention of marking in-development versions as `1.3.0-DEV` is
honoured by default: a `-DEV` suffix is ignored when checking whether the bump is
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

## What is and is not detected

**Detected:** removed or added exports and `public` declarations; removed,
narrowed or added methods (including arities produced by default arguments and
`Vararg`); keyword arguments added, removed or made required; struct fields
added, removed, reordered or retyped; mutability, supertype and type-parameter
changes; `const` type changes; `@enum` definitions; extensions of foreign
functions that the package re-exports (`Base.push!`); definitions reached
through `include` and inside `ext/`.

**Not detected:** the *signatures* of names that are reexported from a
dependency (`@reexport using Foo`) or generated at runtime by `@eval` loops —
they are not defined in the package's own source, so there is nothing to read.
Such names are still compared by name, so dropping one is still caught as a
major change. Behavioural changes that leave signatures intact are also
invisible, by construction.

`--verbose` lists exactly what could not be analyzed, per package, so the blind
spots are never silent:

```
✓ MLJ: unchanged since v0.20.7
    [note] 165 of 168 public name(s) are not defined in this package
           (reexported or generated); compared by name only: …
    [note] `@eval` block at src/loading.jl:41 not analyzed statically
```

Only names the package `export`s or declares `public` are compared. Internal
churn never triggers more than a patch.

## Documentation

- [Using SemverChecker in CI](docs/src/ci.md) — GitHub Actions, GitLab CI,
  Buildkite, and pre-commit.

## License

MIT.
