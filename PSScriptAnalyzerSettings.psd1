@{
    # Fail on Warnings and Errors; ignore Information-level rules.
    Severity     = @('Error', 'Warning')

    # PSAvoidUsingWriteHost -- this project is deliberately console-first;
    # Write-Host is the intended API for the user-facing SUCCESS/ERROR summary,
    # matching the sibling extract-audio-ffmpeg project's style.
    ExcludeRules = @('PSAvoidUsingWriteHost')

    # Everything else stays on. If we ever need to whitelist rules explicitly,
    # switch to `IncludeRules = @(...)` -- for now, all built-in rules apply.
}
