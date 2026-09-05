# Command line entry point.  Hand-rolled argument parsing keeps this package
# dependency-light, which matters when it is installed into a CI job.

const USAGE = """
SemverChecker — remind developers to bump versions during development.

Usage:
    julia -e 'using SemverChecker; SemverChecker.main()' -- [options] [path]

Options:
    --path=DIR            Repository to scan (default: ".", or the positional argument)
    --package=DIR         Check only this package directory; repeatable
    --format=FMT          auto | text | github | markdown | json  (default: auto)
    --summary             Also append a Markdown report to \$GITHUB_STEP_SUMMARY
    --fix                 Rewrite Project.toml versions to the minimum acceptable
    --logdir=DIR          Keep the analysis subprocess logs here
    --skip=NAME           Directory name to skip during discovery; repeatable
    --no-prerelease       Do not treat "1.2.0-DEV" as satisfying a bump to 1.2.0
    --verbose             Show packages that are already fine, and analysis notes
    --exit-zero           Always exit 0 (report only, never fail the build)
    --help                Show this message

Exit status is 1 when at least one package needs a version bump, 0 otherwise.

"auto" picks `github` when \$GITHUB_ACTIONS is set, and `text` otherwise; in the
GitHub case a human-readable report is printed alongside the annotations.
"""

"""
    main(args=ARGS) -> Int

Run the check as a command line tool.  Returns the process exit code; when
running under `julia -e ...` call `exit(SemverChecker.main())` to propagate it.
"""
function main(args::AbstractVector{<:AbstractString}=ARGS)
    opts = Dict{String,Any}(
        "path" => ".", "format" => "auto", "fix" => false, "verbose" => false,
        "summary" => false, "exit_zero" => false, "allow_prerelease" => true,
        "logdir" => nothing,
    )
    packages = String[]
    skips = copy(DEFAULT_SKIP)

    for a in args
        if a == "--help" || a == "-h"
            print(stdout, USAGE)
            return 0
        elseif a == "--fix"
            opts["fix"] = true
        elseif a == "--verbose" || a == "-v"
            opts["verbose"] = true
        elseif a == "--summary"
            opts["summary"] = true
        elseif a == "--exit-zero"
            opts["exit_zero"] = true
        elseif a == "--no-prerelease"
            opts["allow_prerelease"] = false
        elseif startswith(a, "--path=")
            opts["path"] = a[8:end]
        elseif startswith(a, "--logdir=")
            opts["logdir"] = a[10:end]
        elseif startswith(a, "--format=")
            opts["format"] = a[10:end]
        elseif startswith(a, "--package=")
            push!(packages, a[11:end])
        elseif startswith(a, "--skip=")
            push!(skips, a[8:end])
        elseif startswith(a, "-")
            println(stderr, "unrecognised option: $(a)\n")
            print(stderr, USAGE)
            return 2
        else
            opts["path"] = a
        end
    end

    root = abspath(opts["path"])
    isdir(root) || (println(stderr, "no such directory: $(root)"); return 2)

    logdir = opts["logdir"] === nothing ? mktempdir() : opts["logdir"]
    reports = check(root;
                    packages = isempty(packages) ? nothing : packages,
                    skip = skips,
                    allow_prerelease = opts["allow_prerelease"],
                    logdir = logdir)

    if isempty(reports)
        println(stderr, "no Julia packages found under $(root)")
        return opts["exit_zero"] ? 0 : 2
    end

    fmt = opts["format"]
    fmt == "auto" && (fmt = haskey(ENV, "GITHUB_ACTIONS") ? "github" : "text")

    if fmt == "json"
        print_json(stdout, reports)
    elseif fmt == "markdown"
        print_markdown(stdout, reports)
    elseif fmt == "github"
        print_report(stdout, reports; verbose=opts["verbose"], color=false)
        print_github_annotations(stdout, reports; root)
    else
        print_report(stdout, reports; verbose=opts["verbose"])
    end

    if opts["summary"]
        path = get(ENV, "GITHUB_STEP_SUMMARY", "")
        if isempty(path)
            @warn "--summary given but GITHUB_STEP_SUMMARY is not set"
        else
            open(path, "a") do io
                print_markdown(io, reports)
            end
        end
    end

    # A package that could not be loaded is usually explained by the subprocess
    # log, so point at it rather than leaving the user to guess.
    if any(r -> r.status === :error, reports)
        println(stderr, "\nanalysis logs: $(logdir)")
    end

    if opts["fix"]
        for p in apply_bumps!(reports; root)
            println(stdout, "updated $(relpath(p, root))")
        end
        return 0
    end

    n_bad = count(r -> r.status === :needs_bump, reports)
    return (n_bad > 0 && !opts["exit_zero"]) ? 1 : 0
end
