#!/usr/bin/env nu
# Structural validation for the ting nix flake, without a nix binary
# (nushell port of the original python validator).
#
# 1. Nix lexer: skip strings ("..."), ''...'' strings, comments; then check
#    (), [], {} balance per file and track that every opened attrset closes.
# 2. Simulate the composer's ctx contract: theme section files may only
#    reference ctx keys {css, palettes, P, G, M, WC, D, V} — verify each
#    `inherit (ctx)` line stays inside that set.
# 3. Verify that every ${...} interpolation inside '' strings of theme
#    files references names that are plausibly in scope.
# 4. Cross-file sanity: composer imports, palette contract, chrome and
#    Sidebery selectors, DarkReader wiring.

def flake-root [] {
  # The theme's root: this script lives in <root>/checks/.
  $env.CURRENT_FILE? | default "." | path dirname | path dirname
}

const CTX_KEYS = ["css" "palettes" "P" "G" "M" "WC" "D" "V"]
const FIXED_SCOPE = ["css" "palettes" "P" "G" "M" "WC" "D" "V" "lib" "pkgs"
  "config" "out" "resolvedPalette" "normalized" "c" "vars" "cssVars"
  "tingLib" "ctx" "body" "floatBody" "sections" "palette" "builtins"
  "toString" "throw" "null" "true" "false" "import" "map" "self" "nixpkgs"
  "systems" "forAllSystems" "args"]

# Blank all non-newline chars of a run; ''-strings also keep {} so the
# ${ } shells of interpolations stay visible for brace balance.
def blank-run [body: string, --braces] {
  if $braces {
    $body | str replace -ar '[^\n{}]' ' '
  } else {
    $body | str replace -ar '[^\n]' ' '
  }
}

# Nearest event among several index-of results (-1 = none present).
def nearest [idxs: list] {
  let hits = ($idxs | where {|p| $p >= 0 })
  if ($hits | is-empty) { -1 } else { $hits | math min }
}

# Consume a ${ ... } shell; returns { txt, i } with raw interpolation text
# (interpolations are nix code — they must stay visible) and the new index.
def scan-interp [src: string, start: int] {
  mut txt = "${"
  mut depth = 1
  mut j = $start
  let n = ($src | into binary | bytes length)
  while $j < $n and $depth > 0 {
    let c = ($src | str substring $j..$j)
    if $c == "{" {
      $depth += 1
    } else if $c == "}" {
      $depth -= 1
    }
    $txt = $txt + $c
    $j += 1
  }
  { txt: $txt, i: $j }
}

# Return source with comments and string contents blanked out, keeping
# newlines and any ${ } interpolation shells. Chunked: whole code runs and
# string runs are emitted as single pieces (fast on multi-KB files).
def strip-nix [src: string] {
  let n = ($src | into binary | bytes length)
  mut parts = []
  mut i = 0
  loop {
    if $i >= $n { break }
    let rest = ($src | str substring $i..)
    let rel = (nearest [
      ($rest | str index-of "#")
      ($rest | str index-of "/*")
      ($rest | str index-of "''")
      ($rest | str index-of "\"")
    ])
    if $rel < 0 {
      $parts = ($parts | append $rest)
      break
    }
    if $rel > 0 {
      $parts = ($parts | append ($rest | str substring 0..($rel - 1)))
    }
    $i = $i + $rel
    let ch = ($src | str substring $i..$i)
    if $ch == "#" {
      let nl = (($src | str substring $i..) | str index-of "\n")
      $i = (if $nl < 0 { $n } else { $i + $nl + 1 })
    } else if ($src | str substring $i..($i + 1)) == "/*" {
      let close = (($src | str substring ($i + 2)..) | str index-of "*/")
      $i = (if $close < 0 { $n } else { $i + 2 + $close + 2 })
    } else if ($src | str substring $i..($i + 1)) == "''" {
      $parts = ($parts | append "''")
      $i = $i + 2
      loop {
        if $i >= $n {
          $parts = ($parts | append "''")
          break
        }
        let s2 = ($src | str substring $i..)
        let ev = (nearest [ ($s2 | str index-of "${") ($s2 | str index-of "''") ])
        if $ev < 0 {
          $parts = ($parts | append (blank-run $s2 --braces))
          $parts = ($parts | append "''")
          $i = $n
          break
        }
        if $ev > 0 {
          $parts = ($parts | append (blank-run ($s2 | str substring 0..($ev - 1)) --braces))
        }
        let tok = ($s2 | str substring $ev..($ev + 1))
        if $tok == "${" {
          let r = (scan-interp $src ($i + $ev + 2))
          $parts = ($parts | append $r.txt)
          $i = $r.i
        } else {
          $parts = ($parts | append "''")
          $i = $i + $ev + 2
          break
        }
      }
    } else {
      # double-quoted string
      $parts = ($parts | append " ")
      $i = $i + 1
      loop {
        if $i >= $n { break }
        let s2 = ($src | str substring $i..)
        let ev = (nearest [
          ($s2 | str index-of "\"")
          ($s2 | str index-of "${")
          ($s2 | str index-of "\\")
        ])
        if $ev < 0 {
          $parts = ($parts | append (blank-run $s2))
          $i = $n
          break
        }
        if $ev > 0 {
          $parts = ($parts | append (blank-run ($s2 | str substring 0..($ev - 1))))
        }
        let tok = ($s2 | str substring $ev..$ev)
        if $tok == "\"" {
          $parts = ($parts | append " ")
          $i = $i + $ev + 1
          break
        } else if $tok == "$" {
          let r = (scan-interp $src ($i + $ev + 2))
          $parts = ($parts | append $r.txt)
          $i = $r.i
        } else {
          # backslash escape: skip two raw chars (python parity)
          $i = $i + $ev + 2
        }
      }
    }
  }
  $parts | flatten | str join ""
}

def balance-check [path: string, src: string] {
  mut errs = []
  mut stack = []
  mut line = 1
  for ch in ($src | split chars) {
    if $ch == "\n" {
      $line += 1
    } else if $ch in "([{" {
      $stack = ($stack | append { o: $ch, l: $line })
    } else if $ch in ")]}" {
      if ($stack | is-empty) {
        $errs = ($errs | append $"  ($path):($line): unmatched '($ch)'")
      } else {
        let top = ($stack | last)
        $stack = ($stack | drop)
        let want = (match $top.o { "(" => ")", "[" => "]", "{" => "}", _ => "?" })
        if $want != $ch {
          $errs = ($errs | append $"  ($path):($line): '($ch)' closes '($top.o)' from line ($top.l)")
        }
      }
    }
  }
  for s in $stack {
    $errs = ($errs | append $"  ($path):($s.l): unclosed '($s.o)'")
  }
  $errs
}

def ctx-check [path: string, stripped: string] {
  mut errs = []
  for h in ($stripped | parse --regex 'inherit\s*\((?P<src>[^)]+)\)\s*(?P<names>[^;]+);') {
    if ($h.src | str trim) == "ctx" {
      for name in ($h.names | split words) {
        if $name not-in $CTX_KEYS {
          $errs = ($errs | append $"  ($path): inherits '($name)' from ctx — outside contract")
        }
      }
    }
  }
  $errs
}

def interpolation-check [path: string, raw: string] {
  mut scope = $FIXED_SCOPE
  let stripped = (strip-nix $raw)
  # let bindings & attrset keys (name = / name :)
  for m in ($stripped | parse --regex '(?m)^\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*(?:=|:)') {
    $scope = ($scope ++ [$m.name])
  }
  # inherit (x) a b c;
  for m in ($stripped | parse --regex 'inherit\s*\(([^)]+)\)\s*([^;]+);') {
    $scope = ($scope ++ ($m.capture1 | split words))
  }
  # lambda params anywhere: x: body  /  x ? default
  for m in ($stripped | parse --regex '\b(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*[:?]') {
    $scope = ($scope ++ [$m.name])
  }
  # destructured args {a b c}:
  for m in ($stripped | parse --regex '\{(?P<body>[^{}]*?)\}\s*:') {
    $scope = ($scope ++ ($m.body | parse --regex '([A-Za-z_][A-Za-z0-9_]*)' | get capture0))
  }
  mut errs = []
  for m in ($raw | parse --regex '\$\{(?P<expr>[A-Za-z_][A-Za-z0-9_.]*)') {
    let root = ($m.expr | split row "." | first | str trim --right --char "'")
    if $root not-in $scope {
      $errs = ($errs | append $"  ($path): interpolation '${($m.expr)}' — root '($root)' not obviously in scope")
    }
  }
  $errs
}

def main [] {
  mut errs = []
  let ROOT = (flake-root)
  let files = (glob $"($ROOT)/**/*.nix" --depth 10 | sort)

  for path in $files {
    let rel = ($path | str replace $"($ROOT)/" "")
    let raw = (open --raw $path)
    let stripped = (strip-nix $raw)
    $errs = ($errs ++ (balance-check $rel $stripped))
    $errs = ($errs ++ (ctx-check $rel $stripped))
    $errs = ($errs ++ (interpolation-check $rel $raw))
  }

  # ---- cross-file sanity -------------------------------------------------
  let composer = (open --raw $"($ROOT)/lib/composer.nix")
  # userChrome's sections are listed in modules/chrome.nix; the separate
  # documents are imported by the composer itself.
  let sections = (open --raw $"($ROOT)/modules/chrome.nix")
  for section in ["base" "tabbar" "urlbar" "sidebar" "popups" "misc"] {
    if not ($sections | str contains $"./chrome/($section).nix") {
      $errs = ($errs ++ [($"  modules/chrome.nix: section ($section) not listed")])
    }
  }
  if not ($composer | str contains "../modules/chrome.nix") {
    $errs = ($errs ++ ["  composer.nix: modules/chrome.nix not imported"])
  }
  for section in ["content" "darkreader"] {
    if not ($composer | str contains $"../modules/chrome/($section).nix") {
      $errs = ($errs ++ [($"  composer.nix: section ($section) not imported")])
    }
  }
  for var in ["vt-panel-alpha" "vt-chrome-alpha" "vt-popup-alpha"
              "vt-accent-rgb" "vt-surface-rgb" "vt-text-dim-rgb"] {
    # the composer writes `vt-panel-alpha = ...;` — varsBlock adds the -- prefix
    if not ($composer | str contains $var) {
      $errs = ($errs ++ [($"  composer.nix: palette contract var --($var) missing")])
    }
  }

  mut chrome = ""
  for s in ["base" "tabbar" "urlbar" "sidebar" "popups" "misc"] {
    $chrome = $chrome + (open --raw $"($ROOT)/modules/chrome/($s).nix")
  }
  for sel in ["#navigator-toolbox" "#nav-bar" "#urlbar-background" ".urlbarView"
              "#sidebar-box" "menupopup" "findbar" "#PersonalToolbar"] {
    if not ($chrome | str contains $sel) {
      $errs = ($errs ++ [($"  theme sections: selector ($sel) missing")])
    }
  }

  let sb = (open --raw $"($ROOT)/modules/chrome/sidebery.nix")
  for sel in [".Tab" ".NavigationBar" "#root" "data-active"] {
    if not ($sb | str contains $sel) {
      $errs = ($errs ++ [($"  sidebery.nix: ($sel) missing")])
    }
  }

  # DarkReader wiring (palette-driven web content theming)
  let dr = (open --raw $"($ROOT)/modules/chrome/darkreader.nix")
  for tok in ["V.dark" "V.light" "color-scheme" ":root"] {
    if not ($dr | str contains $tok) {
      $errs = ($errs ++ [($"  darkreader.nix: ($tok) missing")])
    }
  }
  let content = (open --raw $"($ROOT)/modules/chrome/content.nix")
  for tok in ["--in-content-page-background" "V.dark" "V.light" "about:newtab"] {
    if not ($content | str contains $tok) {
      $errs = ($errs ++ [($"  content.nix: ($tok) missing")])
    }
  }
  for tok in ['ting.darkreader.off' 'prefers-color-scheme' 'webGuard ='] {
    if not ($composer | str contains $tok) {
      $errs = ($errs ++ [($"  composer.nix: darkreader wiring '($tok)' missing")])
    }
  }

  if ($errs | is-empty) {
    print $"OK: ($files | length) nix files — balance, ctx contract, interpolation scope, selector presence, darkreader wiring all pass"
  } else {
    print "FAIL:"
    for e in $errs { print $e }
    exit 1
  }
}
