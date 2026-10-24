# Fresh values for nixtamal inputs: `nu --no-config-file nix/fresh.nu <command> ...`.

# The newest release tag of a Git repository: the highest `X.Y.Z`, with or without a leading `v`.
def newest-tag [repository: string]: nothing -> string {
  let tags = ^git ls-remote --exit-code --tags --refs $repository
  | from tsv --noheaders
  | rename revision reference
  | update reference { str replace 'refs/tags/' '' }
  | where reference =~ '^v?\d+\.\d+\.\d+$'
  if ($tags | is-empty) { error make {msg: $"($repository) has no release tag"} }
  $tags
  | insert version {|tag| $tag.reference | str replace --regex '^v' '' | split row '.' | each { into int } }
  | sort-by version
  | last
  | get reference
}

# Print the newest release tag of a Git repository.
def "main release" [repository: string]: nothing -> nothing {
  print (newest-tag $repository)
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
