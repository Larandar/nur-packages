# Pull requests on GitHub, through `gh` in the repository `$env.GH_REPO`, authenticated by `$env.GH_TOKEN`.

# Open pull requests from `branch` into `target`, as their numbers.
def open-pulls [branch: string, target: string]: nothing -> list<int> {
    ^gh pr list --head $branch --base $target --state open --json number | from json | get number
}

# Open a pull request from the pushed `branch` into `target`, or retitle the open one; GitHub follows the branch's
# pushes itself. Returns the pull request's URL.
export def open-or-update [branch: string, target: string, title: string, body: string]: nothing -> string {
    let existing = open-pulls $branch $target
    if ($existing | is-empty) {
        let created = ^gh pr create --head $branch --base $target --title $title --body $body | complete
        if $created.exit_code != 0 {
            if ($created.stderr | str contains "GitHub Actions is not permitted to create or approve pull requests") {
                print --stderr $"Warning: ($branch) was pushed without a pull request. Enable Settings > Actions > General > Workflow permissions > Allow GitHub Actions to create and approve pull requests. Verification will continue."
                return ""
            }
            error make {msg: $"Failed to create pull request for ($branch): ($created.stderr | str trim)"}
        }
        $created.stdout | str trim
    } else {
        let number = $existing | last
        ^gh pr edit $number --title $title --body $body | ignore
        ^gh pr view $number --json url | from json | get url
    }
}

# Close the open pull requests from `branch` into `target`, saying it landed as `commit`: the landed commit is curated
# from the branch, not merged, so GitHub cannot mark the pull request merged itself.
export def settle [branch: string, target: string, commit: string]: nothing -> nothing {
    for number in (open-pulls $branch $target) {
        ^gh pr close $number --comment $"Landed on `($target)` as ($commit)." | ignore
    }
}
