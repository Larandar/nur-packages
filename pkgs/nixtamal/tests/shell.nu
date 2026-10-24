# Exercise the packaged CLI without relying on the caller's Nu or utilities.
use std/assert

export def main [binary: path] {
    let executable = $binary | path expand
    let directory = mktemp -d -t nixtamal-shell.XXXXXXXX
    try {
        let manifest = {|body|
            $'version "1.5.0"
inputs {
    probe {
        file { url "file:///dev/null"; }
        fresh-cmd shell="nu" {
            ($body)
        }
    }
}
' | save --force --raw ($directory | path join manifest.kdl)
        }
        {
            v: '1.5.0'
            i: {
                probe: {
                    sn: probe-src
                    kd: [
                        0
                        {
                            ft: 0
                            ur: 'file:///dev/null'
                            ms: []
                        }
                    ]
                    ha: {al: 0, vl: 'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='}
                    fv: old
                    ps: []
                }
            }
            p: {}
        } | to json | save ($directory | path join lock.json)
        let invoke = {|arguments| with-env {PATH: '', HOME: $directory} {
                ^$executable ...$arguments --directory $directory --color never --jobs 1 | complete
            } }

        do $manifest '$ printf "%s" "{\"tag_name\":\"v1.2.3\"}"; | from json; | get tag_name;'
        let success = do $invoke [list-stale]
        assert equal $success.exit_code 0 $success.stderr
        # list-stale can swallow per-input errors upstream; require the result itself.
        assert (($success.stdout + $success.stderr) | str contains 'probe: v1.2.3')

        do $manifest '$ nu --no-config-file -c "print --stderr shell-failure-marker; exit 7";'
        let failure = do $invoke [lock --force --no-tui probe]
        assert equal $failure.exit_code 71
        assert ($failure.stderr | str contains shell-failure-marker)

        do $manifest '$ printf "%s" "";'
        let empty = do $invoke [lock --force --no-tui probe]
        assert equal $empty.exit_code 72

        open --raw ($directory | path join manifest.kdl)
        | str replace 'shell="nu"' 'shell=""'
        | save --force --raw ($directory | path join manifest.kdl)
        let invalid = do $invoke [check-soundness]
        assert equal $invalid.exit_code 68
    } catch {|err|
        rm --recursive --force $directory
        error make $err
    }
    rm --recursive --force $directory
    print 'nixtamal-shell-test: packaged Nu, structured pipeline, errors and empty output passed'
}
