# Using SemverChecker in CI

SemverChecker is designed to run on pull requests as a reminder: it fails the
job while a package's `Project.toml` still claims a version that its changes
have outgrown, and passes as soon as the developer bumps it.

It works by loading both the released version and the working tree and comparing
them with real Julia dispatch, so the job needs to install and load your
packages. Two things follow, and both are addressed below:

- **Cache the depot.** With `julia-actions/cache@v2` the whole check runs in
  seconds; without it, the released versions are downloaded and precompiled from
  scratch every run.
- **The job needs registry and package-server access**, like any `Pkg.add`.

---

## GitHub Actions

### The minimal workflow

Save as `.github/workflows/semver.yml`:

```yaml
name: Version bump

on:
  pull_request:
    branches: [main]

jobs:
  semver:
    name: Check version bumps
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: julia-actions/setup-julia@v2
        with:
          version: '1'

      - uses: julia-actions/cache@v2

      - name: Check that versions are bumped
        run: |
          julia --color=yes -e '
            using Pkg
            Pkg.activate(temp=true)
            Pkg.add("SemverChecker")
            using SemverChecker
            exit(SemverChecker.main())' -- --summary
```

`SemverChecker.main()` reads `ARGS`, so everything after `--` is passed
through as options. With `$GITHUB_ACTIONS` set, the output format defaults to
`github`: findings become inline annotations on the `version` line of each
offending `Project.toml`, so reviewers see them directly on the pull request
diff. `--summary` additionally writes a Markdown table to the job summary page.

### Only checking packages the pull request touched

On a large monorepo you may only want to nag about packages that this pull
request actually modified. `--package` takes an explicit directory and is
repeatable:

```yaml
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0        # needed to diff against the base branch

      - name: Find touched packages
        id: touched
        run: |
          # Every directory containing a Project.toml that has changed files under it.
          PKGS=$(git diff --name-only origin/${{ github.base_ref }}...HEAD \
                 | xargs -r -n1 dirname \
                 | while read d; do
                     while [ "$d" != "." ] && [ ! -f "$d/Project.toml" ]; do d=$(dirname "$d"); done
                     [ -f "$d/Project.toml" ] && echo "$d"
                   done | sort -u | sed 's/^/--package=/' | tr '\n' ' ')
          echo "args=$PKGS" >> "$GITHUB_OUTPUT"

      - name: Check that versions are bumped
        if: steps.touched.outputs.args != ''
        run: |
          julia --color=yes -e '
            using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
            using SemverChecker; exit(SemverChecker.main())' -- ${{ steps.touched.outputs.args }} --summary
```

### Warning instead of failing

Early in a project you may want the report without a red X. `--exit-zero`
always exits `0`:

```yaml
      - name: Version bump reminder (advisory)
        run: |
          julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
                    using SemverChecker; exit(SemverChecker.main())' -- --exit-zero --summary
```

The annotations still appear; the job just stays green.

### Letting a label override the check

A useful escape hatch for pull requests that deliberately should not bump
(documentation-only changes to a package's `src/`, say):

```yaml
      - name: Check that versions are bumped
        if: ${{ !contains(github.event.pull_request.labels.*.name, 'skip-version-check') }}
        run: |
          julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
                    using SemverChecker; exit(SemverChecker.main())' -- --summary
```

### Posting the report as a pull request comment

`--format=markdown` writes a report suitable for a comment body:

```yaml
      - name: Build report
        id: report
        run: |
          julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
                    using SemverChecker; SemverChecker.main()' \
            -- --format=markdown --exit-zero > semver-report.md
          echo "needs_bump=$(grep -c 'need a version bump' semver-report.md)" >> "$GITHUB_OUTPUT"

      - name: Comment on the pull request
        if: steps.report.outputs.needs_bump != '0'
        uses: peter-evans/create-or-update-comment@v4
        with:
          issue-number: ${{ github.event.pull_request.number }}
          body-path: semver-report.md
```

Pair this with `peter-evans/find-comment` and `comment-id` if you would rather
update a single comment in place than add one per push.

### Pinning the checker

Adding `SemverChecker` resolves to the newest compatible release each run. To
keep CI reproducible, pin it:

```yaml
          julia -e '
            using Pkg
            Pkg.activate(temp=true)
            Pkg.add(PackageSpec(name="SemverChecker", version="0.1"))
            using SemverChecker
            exit(SemverChecker.main())' -- --summary
```

---

## GitLab CI

```yaml
version-bump:
  image: julia:1
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
  script:
    - |
      julia --color=yes -e '
        using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
        using SemverChecker; exit(SemverChecker.main())' -- --format=text
  artifacts:
    when: always
    paths: [semver-report.json]
```

To keep a machine-readable artifact as well, run it twice — once for the human
log, once with `--format=json --exit-zero > semver-report.json`.

---

## Buildkite

```yaml
steps:
  - label: ":julia: version bump"
    plugins:
      - JuliaCI/julia#v1:
          version: "1"
    command: |
      julia --color=yes -e '
        using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
        using SemverChecker; exit(SemverChecker.main())'
```

To annotate the build instead of only failing it:

```bash
julia -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
          using SemverChecker; SemverChecker.main()' \
  -- --format=markdown --exit-zero | buildkite-agent annotate --style warning --context semver
```

---

## Locally, before you push

Run the same check by hand:

```console
$ julia -e 'using SemverChecker; exit(SemverChecker.main())' -- --verbose
```

Or let it do the bumping for you:

```console
$ julia -e 'using SemverChecker; SemverChecker.main()' -- --fix
updated BinaryBuilderProducts.jl/Project.toml
updated ScratchSpaceGarbageCollector.jl/Project.toml
```

`--fix` sets each version to the *minimum* acceptable value. Review the diff —
the tool cannot know that you intended `2.0.0` rather than `1.4.0`.

### As a git pre-push hook

`.git/hooks/pre-push`:

```bash
#!/bin/sh
julia --project=@semvercheck -e 'using SemverChecker; exit(SemverChecker.main())' -- --exit-zero
```

Create the shared environment once with:

```console
$ julia --project=@semvercheck -e 'using Pkg; Pkg.add("SemverChecker")'
```

---

## Interpreting the report

```
✗ MyPackage: bump version to at least 2.0.0 (currently 1.4.2, released 1.4.2, detected major change)
    [major] `parse_config` is no longer exported
    [major] `Config` gained field `timeout::Float64` (changes layout and the default constructor)
    [minor] new method `render(Config, IO)`  (src/render.jl:88)
```

Every line names the change that drove the verdict and where it lives, so you
can decide whether the break was intentional. If it was, bump to the suggested
version. If it was not, the report has just caught a regression.

Three verdicts are informational rather than failures:

- `unregistered` — the package is not in any reachable registry, so there is
  nothing to compare against. New packages sit here until their first release.
- `no_version` — `Project.toml` has no `version` field.
- `error` — the released version could not be installed or loaded, or the
  working tree could not be. The message says which, and `--logdir` keeps the
  subprocess output that explains it. These surface as `::warning` annotations on
  GitHub, so an unloadable package or a package-server outage does not fail your
  build.

### Registries other than General

`check` searches every reachable registry, so packages registered in a private
registry work as long as CI has that registry installed:

```yaml
      - name: Add the private registry
        run: |
          julia -e 'using Pkg
                    Pkg.Registry.add(RegistrySpec(url="https://github.com/MyOrg/MyRegistry"))'
```

Add it before running the check, in the same job.

### Caching

Caching is worth more here than in most jobs, because the released versions are
installed and precompiled as well as the working tree. Measured on
BinaryBuilder2's thirteen packages:

| | released side | working tree | total |
|---|---|---|---|
| Warm depot (`julia-actions/cache`) | ~3s | ~1s | **~15s** |
| Cold depot | ~155s, 2.6GB | ~46s | ~3.5min |

Always include the cache step:

```yaml
      - uses: julia-actions/cache@v2
```

If the same workflow also runs your tests, put the check in the *same* job as
the tests so the working tree is precompiled only once.

### When a package will not load

A package that cannot be resolved or loaded — on either side — is reported as an
error rather than a verdict, and the other packages still get theirs. The
subprocess output explains why; keep it with `--logdir` and upload it:

```yaml
      - name: Check that versions are bumped
        run: |
          julia --color=yes -e '
            using Pkg; Pkg.activate(temp=true); Pkg.add("SemverChecker")
            using SemverChecker; exit(SemverChecker.main())' -- --summary --logdir=semver-logs

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: semver-logs
          path: semver-logs/
```
