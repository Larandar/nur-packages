{pkgs}:
pkgs.runCommand "ci-prepare-test" {
  nativeBuildInputs = [pkgs.git pkgs.jujutsu pkgs.nushell];
} ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME" checkout/nix
  cp ${../toolkit.nu} checkout/toolkit.nu
  cp ${../nix/github.nu} checkout/nix/github.nu
  cd checkout
  git init --initial-branch=main
  git -c user.name=test -c user.email=test@example.invalid commit --allow-empty -m initial
  git remote add origin "$PWD"
  nu --no-config-file -c '
    use std/assert
    overlay use --prefix toolkit.nu
    hide-env --ignore-errors NUR_CI_NAME NUR_CI_EMAIL
    toolkit ci-prepare
    assert equal (^jj config get user.name | str trim) "nur-packages CI"
    assert equal (^jj config get user.email | str trim) "ci@nur-packages.invalid"
    let cases = [
      {name: "github-actions[bot]", email: "41898282+github-actions[bot]@users.noreply.github.com"}
      {name: $"CI (char squote)quoted(char squote) \"bot\" \\ runner", email: "bot[ci]@example.invalid"}
      {name: "true", email: "123"}
    ]
    for case in $cases {
      $env.NUR_CI_NAME = $case.name
      $env.NUR_CI_EMAIL = $case.email
      toolkit ci-prepare
      assert equal (^jj config get user.name | str trim) $case.name
      assert equal (^jj config get user.email | str trim) $case.email
      let author = ^jj log --no-graph -r @ -T "author.name() ++ \"\n\" ++ author.email()" | lines
      assert equal $author [$case.name $case.email]
    }
  '
  touch "$out"
''
