#!/usr/bin/env nu
# Smoke-test the ting timepalette engine outside nix (nushell port of
# the original python test). Run: nu checks/test_timepalette.nu

def flake-root [] {
  # The theme's root: this script lives in <root>/checks/.
  $env.CURRENT_FILE? | default "." | path dirname | path dirname
}

def fail [msg: string] {
  print $"FAIL: ($msg)"
  exit 1
}

def main [] {
  let ROOT = (flake-root)
  let TMP = (($env.PWD? | default ".") | path join ".tmp-ting-test")
  let script = ($ROOT | path join "timepalette.nu")
  rm --recursive --force $TMP
  mkdir $TMP
  let cfg_path = ($TMP | path join "config.json")
  let out_path = ($TMP | path join "palette.css")
  let chrome_dir = ($TMP | path join "chrome")
  mkdir $chrome_dir

  {
    colors: {
      bg: "12121c", bgElev: "1a1a2b", surface: "1e1e30",
      surfaceAlt: "262640", border: "353552", text: "eaeaf6",
      textDim: "9d9dc0", accent: "a78bfa", accent2: "67e8f9",
      onAccent: "14142a", danger: "f87171", success: "34d399",
      warning: "fbbf24",
    },
    glass: { panelAlpha: 0.72, chromeAlpha: 0.55, popupAlpha: 0.92 },
    schedule: { dawn: 7, day: 12, dusk: 19, night: 23 },
  } | to json | save --force $cfg_path

  # locate the interpreter: prefer the sandbox binary, else PATH
  let nu_bin = (if ("/home/z/my-project/.tools/nu/nu" | path exists) {
    "/home/z/my-project/.tools/nu/nu"
  } else {
    "nu"
  })

  # 1) first run creates the file and the chrome symlink
  run-external $nu_bin "--no-config-file" $script $cfg_path $out_path $chrome_dir
  if not ($out_path | path exists) {
    fail "engine did not write palette.css"
  }
  let css = (open --raw $out_path)

  # every --vt- var the composer's palette.css contract defines
  let required = ["--vt-bg" "--vt-bg-rgb" "--vt-bg-elev" "--vt-bg-elev-rgb"
    "--vt-surface" "--vt-surface-rgb" "--vt-surface-alt" "--vt-surface-alt-rgb"
    "--vt-border" "--vt-border-rgb" "--vt-text" "--vt-text-rgb"
    "--vt-text-dim" "--vt-text-dim-rgb" "--vt-accent" "--vt-accent-rgb"
    "--vt-accent-2" "--vt-accent-2-rgb" "--vt-on-accent" "--vt-on-accent-rgb"
    "--vt-danger" "--vt-danger-rgb" "--vt-success" "--vt-success-rgb"
    "--vt-warning" "--vt-warning-rgb" "--vt-dark"
    "--vt-panel-alpha" "--vt-chrome-alpha" "--vt-popup-alpha"]
  for v in $required {
    if not ($css | str contains $v) {
      fail $"missing var ($v)"
    }
  }

  let link = ($chrome_dir | path join "palette.css")
  let link_type = (ls --long $chrome_dir
    | where {|r| ($r.name | path basename) == "palette.css" }
    | get 0.type)
  if $link_type != "symlink" {
    fail "chrome/palette.css is not a symlink"
  }
  let dest = (^readlink $link | str trim)
  if ($dest | path expand) != ($out_path | path expand) {
    fail $"symlink points at ($dest), expected ($out_path)"
  }

  # 2) idempotent re-run (symlink already present)
  run-external $nu_bin "--no-config-file" $script $cfg_path $out_path $chrome_dir
  if ((^readlink $link | str trim) != $dest) {
    fail "symlink was re-pointed unexpectedly on re-run"
  }

  # 3) sanity: values are valid rgb triplets / alphas
  for m in ($css | parse -r '--vt-(?P<k>[a-z2-]+)-rgb: (?P<v>[\d ]+);') {
    let parts = ($m.v | split words)
    if ($parts | length) != 3 {
      fail $"bad triplet for ($m.k): ($m.v)"
    }
    for p in $parts {
      let n = ($p | into int)
      if $n < 0 or $n > 255 {
        fail $"triplet out of range for ($m.k): ($m.v)"
      }
    }
  }
  for m in ($css | parse -r '--vt-(?P<k>[a-z2-]+alpha): (?P<v>[\d.]+);') {
    let f = ($m.v | into float)
    if $f < 0.25 or $f > 1.0 {
      fail $"alpha out of range for ($m.k): ($m.v)"
    }
  }

  print $css
  print "OK: timepalette engine passed all checks"
  rm --recursive --force $TMP
}
