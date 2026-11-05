def --wrapped main [tool: string, ...args: string] {
    match $tool {
        nix => {
            match $args.0 {
                develop => { ^bash -c 'env -u FILE_PWD -u CURRENT_FILE -0 > "$0"' ($args | last) }
                build => {
                    if ($args | last) == "searchwala-calf.src" {
                        let input = open nix/tamal/lock.json | get i | get --optional searchwala-calf
                        let tag = open --raw pkgs/searchwala-calf/lock.nix | parse --regex 'tag = "(?<tag>[^"]+)"' | get --optional 0.tag
                        if $input != null and $input.kd.0 == 1 and $tag != $input.fv {
                            print --stderr "searchwala-calf: stale release tag"
                            exit 1
                        }
                    }
                    print $env.TEST_SOURCE
                }
                shell => { "cargo\n" | save --append $env.TEST_LOG }
                eval => {
                    if ($args | last | str contains "p.tests or {}") {
                        if ($env.TEST_DISCOVERY_FAIL? | default false | into bool) and ("concurrent.txt" | path exists) {
                            print --stderr "module evaluation failed"
                            exit 1
                        }
                        print (if ($env.TEST_NO_TESTS? | default false | into bool) { "[]" } else { '["module"]' })
                    } else if "--apply" in $args {
                        print "[]"
                    } else if ($args | last | str ends-with "/lock.nix") {
                        open --raw ($args | last)
                        | parse --regex '(?<key>\w+) = "(?<value>[^"]+)"'
                        | reduce --fold {} {|entry, lock| $lock | insert $entry.key $entry.value }
                        | to json --raw
                        | print
                    } else {
                        print "{}"
                    }
                }
            }
        }
        nixtamal => {}
        iets => {
            let target = $args | last
            $"($target)\n" | save --append $env.TEST_LOG
            if ($env.TEST_FAIL? | default false | into bool) and ("concurrent.txt" | path exists) {
                print --stderr "combined tree failed"
                exit 1
            }
        }
        git => {
            if $args.0 == push {
                $"push\n" | save --append $env.TEST_LOG
                let count = open --raw $env.TEST_LOG | lines | where $it == push | length
                if $count == 1 {
                    print --stderr "rejected"
                    exit 1
                }
            } else if $args.0 == fetch {
                if ($env.TEST_REMOTE? | default "") != "" {
                    ^($env.REAL_GIT) update-ref refs/remotes/origin/main $env.TEST_REMOTE
                }
            } else {
                ^($env.REAL_GIT) ...$args
            }
        }
        gh => {
            match $args.1 {
                list => { print "[]" }
                create => {
                    match $env.TEST_PR {
                        policy => {
                            print --stderr "pull request create failed: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)"
                            exit 1
                        }
                        denied => {
                            print --stderr "Resource not accessible by integration"
                            exit 1
                        }
                        success => { print "https://github.com/example/test/pull/1" }
                    }
                }
            }
        }
    }
}
