# Fresh values for nixtamal inputs: `nu --no-config-file nix/fresh.nu <command> ...`.

# The newest release tag of a Git repository: the highest `X.Y.Z`, with or without a leading `v`. With `stamped`,
# releases are tagged `X.Y.Z-YYYYMMDD-HHMM` instead, and the newest stamp of the highest version wins.
def newest-tag [repository: string, --stamped]: nothing -> string {
  let release = if $stamped { '^v?(\d+\.\d+\.\d+)-(\d{8}-\d{4})$' } else { '^v?(\d+\.\d+\.\d+)()$' }
  let tags = ^git ls-remote --exit-code --tags --refs $repository
  | from tsv --noheaders
  | rename revision reference
  | update reference { str replace 'refs/tags/' '' }
  | where reference =~ $release
  if ($tags | is-empty) { error make {msg: $"($repository) has no release tag"} }
  $tags
  | insert version {|tag| $tag.reference | str replace --regex $release '$1' | split row '.' | each { into int } }
  | insert stamp {|tag| $tag.reference | str replace --regex $release '$2' }
  | sort-by version stamp
  | last
  | get reference
}

# Print the newest release tag of a Git repository.
def "main release" [
  repository: string
  --stamped # Releases carry a build stamp: `X.Y.Z-YYYYMMDD-HHMM`
]: nothing -> nothing {
  print (newest-tag $repository --stamped=$stamped)
}

# Print the version of `crate` locked in the `Cargo.lock` of the source nixtamal input `input` is pinned to.
# Run after that input locks: a companion input follows whatever release or branch head it holds.
def "main locked-dep" [
  input: string # A nixtamal input fetched at evaluation
  crate: string
]: nothing -> nothing {
  let source = ^nix eval --raw --impure --expr $"toString \(import ./nix/tamal {}\).($input)" | str trim
  let versions = open --raw ($source | path join Cargo.lock)
  | from toml
  | get package
  | where name == $crate
  | get version
  | uniq
  if ($versions | length) != 1 {
    error make {msg: $"($input) locks ($versions | length) versions of ($crate), expected one"}
  }
  print $versions.0
}

def main []: nothing -> nothing {
  print (help main)
}
