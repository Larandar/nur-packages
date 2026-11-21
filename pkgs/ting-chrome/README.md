# Ting

**Glassmorphic Firefox chrome, composed in nix — for Wayland and macOS.**

Ting ("stained glass") blends the best idea of ten Firefox theming projects:

| Source | What Ting borrowed |
| --- | --- |
| [EdgyArc-fr](https://github.com/artsyfriedchicken/EdgyArc-fr) | Edge-style floating sidebar card, `-moz-pref` toggle system (`@media -moz-pref()` since Gecko 136) |
| [FF-ULTIMA](https://github.com/soulhotel/FF-ULTIMA) | "everything is an option" composer-driven minimalism, hidden tab strip |
| [TransperentFox](https://github.com/ScanuNicco/TransperentFox) | translucent chrome layering |
| [wmfox](https://github.com/cankurttekin/wmfox) | windowControls = "none" mode for WM users, opaque escape hatch |
| [FoxOne](https://github.com/Firnschnee/FoxOne) | optional floating rounded content cards |
| [malevich](https://github.com/hermitm0nk/malevich) | the *porcelain* light palette (warm terracotta minimalism) |
| [natsumi-browser](https://github.com/greeeen-dev/natsumi-browser) | floating URL bar, glass findbar |
| [safari-firefox](https://github.com/gauravrocks009/safari-firefox) | window controls floating over the nav bar, pill URL field |
| [Glass-Firefox-Theme](https://github.com/ChaosMx11/Glass-Firefox-Theme) | full glassmorphism (panels, menus, about: pages) |
| [Sidebery v5](https://github.com/mbnuqw/sidebery/tree/v5/docs) | complete companion stylesheet + settings snapshot |

Further inspiration, nothing borrowed yet:

* [PotatoFox](https://codeberg.org/da157/PotatoFox)
* [arcwtf](https://github.com/kikaraage/arcwtf)
* [shina-fox](https://github.com/shina-sg/shina-fox)
* [ShyFox](https://github.com/Naezr/ShyFox)
* [parfait](https://github.com/reizumii/parfait)
* [gwfox](https://github.com/akkva/gwfox)
* [arcticfox-theme](https://github.com/sirlan-ff00ff/arcticfox-theme)
* [MightyFox](https://www.reddit.com/r/FirefoxCSS/comments/195n51c/mightyfox_an_idea_need_help_to_build_it_up/), an idea thread
* [Themes similar to Zen](https://www.reddit.com/r/FirefoxCSS/comments/1x96395/themes_similar_to_zen/), a thread
* [r/FirefoxCSS](https://www.reddit.com/r/FirefoxCSS/)

The native tab strip is gone; tabs live in a **Sidebery** sidebar rendered as a
floating glass card. The URL bar is a detached pill. Popups, the findbar, the
bookmarks bar and `about:` pages all follow. Everything is generated from a
nix expression and every color lives in one swappable `palette.css`.

---

## Layout

```text
package.nix          the composed ultraviolet pack (nur-packages'
                     `ting-chrome`; `lib.ting` is the library)
lib/css.nix          pure-nix CSS helpers (hex → rgb triplets, mix, toggles)
lib/composer.nix     the composer: config → generated files
modules/palettes.nix ultraviolet / midnight / porcelain + stylix bridge
modules/chrome.nix   the userChrome sections, in order
modules/chrome/*.nix chrome sections: base, tabbar, urlbar, sidebar,
                     popups, misc, sidebery, content, darkreader
../../modules/waterfox/themes.nix  the waterfox modules' theme = "ting"
timepalette.nu       time-of-day palette engine (nushell); no module runs it
checks/validate_ting.nu  structural validator (nushell)
checks/test_timepalette.nu  daemon smoke test (nushell)
```

Generated output (per configuration):

```text
chrome/userChrome.css   the chrome (references --vt-* vars, no colors)
chrome/palette.css      THE runtime contract — swap me, not the chrome
chrome/userContent.css  about: pages + DarkReader web theming (colors inlined)
/etc/ting/sidebery.css     Sidebery's sidebar CSS (also given as policy)
/etc/ting/sidebery.json    Sidebery's styles as an import file
```

---

## Quick start

Ting is a theme the waterfox modules offer, off until chosen. NixOS
(`nixosModules.waterfox`) wears it in the install, for every profile; Home
Manager (`homeModules.waterfox`) per profile, each taking the top level's
`theme` and `themes.ting` unless it sets its own
(`profiles.<name>.theme = null` keeps one stock).

```nix
programs.waterfox = {
  enable = true;
  theme = "ting";
  themes.ting = {
    # paletteSource = "stylix";  # the default when the host has stylix
    # ultraviolet | midnight | porcelain, without stylix
    paletteName = "ultraviolet";

    compose = {
      geometry = {
        radius = 14;
        blur = 22;                    # glass strength
        urlbarFloat = true;
        sidebarFloat = true;
        contentFloat = false;         # FoxOne floating pages, opt-in
      };

      minimalism = {
        hideTabBar = true;            # Sidebery replaces the strip
        hideSidebarHeader = true;
        hideFirefoxSidebarRail = true;
        bookmarksAutoHide = true;     # reveal while hovering the toolbox
        hideNewtabFooter = true;
      };

      windowControls = "float";       # float | titlebar | none

      darkreader = {
        enable = true;                # re-theme web content with the palette
        mode = null;                  # null (stock pages) | tint | invert
        exempt = [ ];                 # url prefixes left untouched
        followScheme = true;          # follow OS light/dark theme variant
      };
    };
  };
};
```

On NixOS the composed `chrome/` becomes the install's `chrome`, which
AutoConfig registers for every profile, and the [prefs](#prefs) its
preferences; in Home Manager they are the profile's `chrome/` files and
`user.js`.

Sidebery's styles come with it: the theme gives Sidebery's sidebar and
group CSS as the `3rdparty` policy, which Sidebery reads as managed storage
before its own, so they follow the palette on every switch and its Styles
editor no longer changes them. Its other settings stay Sidebery's. In Home
Manager the policies are the install's, so they follow the top level's
`theme`, not a profile's.

1. Install [Sidebery](https://addons.mozilla.org/firefox/addon/sidebery/)
   (force-install it through `policies.ExtensionSettings` to keep it
   declarative) and pin it to the left edge ("Sidebar position: left").
2. Recommended Sidebery settings: nav bar layout **horizontal**,
   tab height comes from the stylesheet already.

Switch, restart Waterfox, done.

### Manual install (any Firefox)

```sh
nix build --file . ting-chrome   # from nur-packages' root
cp -r result/share/ting/chrome ~/.mozilla/firefox/<id>.<profile>/
# macOS: ~/Library/Application Support/Firefox/Profiles/<id>.<profile>/
```

…then set the prefs listed under [Prefs](#prefs) manually.

---

## Palette sources

### builtin

`programs.waterfox.themes.ting.paletteName = "ultraviolet" | "midnight" | "porcelain"`,
or a full inline `programs.waterfox.themes.ting.palette`:

```nix
palette = {
  name = "vapor";
  dark = true;
  colors = {
    bg = "12121c";  bgElev = "1a1a2b"; surface = "1e1e30"; surfaceAlt = "262640";
    border = "353552"; text = "eaeaf6"; textDim = "9d9dc0";
    accent = "a78bfa"; accent2 = "67e8f9"; onAccent = "14142a";
    danger = "f87171"; success = "34d399"; warning = "fbbf24";
  };
  glass = { panelAlpha = 0.72; chromeAlpha = 0.55; popupAlpha = 0.92; };
};
```

### stylix (palette derived from your desktop)

```nix
programs.waterfox.themes.ting = {
  paletteSource = "stylix";      # the default with stylix
  stylixAccentBase = "base0C";   # any base08..base0E slot
};
```

Maps `config.lib.stylix.colors` (base00–base0F) onto the Ting palette, so
the browser follows your wallpaper; `stylix.polarity` picks the glass.
`lib.ting.fromStylix` does the same outside the module.

---

## DarkReader — palette-driven web content

`programs.waterfox.themes.ting.compose.darkreader` re-themes **web pages**
(not just `about:` pages) with your palette — the Dark Reader idea, but
generated from the same nix expression as the chrome. The CSS engines are
opt-in: by default web pages keep their own colors, and the Dark Reader
extension, if you use it, is yours to configure by hand.

```nix
programs.waterfox.themes.ting.compose.darkreader = {
  enable = true;             # on by default
  mode = "tint";             # null (the default) | tint | invert
  exempt = [ "https://example.com" ];  # left untouched (undo block emitted)
  aboutPages = true;         # keep the about:/newtab re-skin
  followScheme = true;       # emit light AND dark variants
  lightPalette = null;       # optional explicit light-variant palette
};
```

### Engines

| mode | how | trade-off |
| --- | --- | --- |
| `tint` | targeted palette-colored overrides: html/body, links, headings, forms, code, tables, selection, scrollbars + `color-scheme` | honest heuristic — layout and `position:fixed` survive; some sites leak their own colors |
| `invert` | `filter: invert(1) hue-rotate(180deg)` on `html`, media re-inverted; the canvas is pre-painted with the per-channel inverse of your palette so the filter lands exactly on it | converts everything, but breaks `position:fixed` on some pages |

**Light/dark variants.** With `followScheme = true` (default) every rule is
evaluated twice — once against your palette, once against the *opposite*
polarity — and wrapped in `prefers-color-scheme` media queries. The module
pins Firefox to system-follow (`layout.css.prefers-color-scheme.content-
override = 2`), so web content and about: pages switch
when your desktop theme switches — including time-based schedulers. The
opposite polarity is *derived* like Dark Reader does: luminance inverted,
hues kept (`<palette>-daylight` / `<palette>-nocturne`), or supply your own
with `lightPalette`. With `followScheme = false` content is pinned to the
palette's own polarity.

**Exemptions** emit a per-site `unset` undo block after the theme rules, so
listed prefixes stay fully stock. Printing is always stock (`@media print`
guard). Runtime escape hatch: `ting.darkreader.off = true` in
about:config disables web theming without a rebuild.

---

## Runtime toggles (about:config)

EdgyArc-style escape hatches; each exists only when the composer made it
relevant:

| Pref | Effect |
| --- | --- |
| `ting.opaque` | force solid surfaces, drop every backdrop-filter (wmfox mode, screenshots) |
| `ting.tabbar.show` | restore the native tab strip (when hidden at build) |
| `ting.urlbar.dock` | dock the URL bar (when floating at build) |
| `ting.sidebar.dock` / `ting.sidebar.float` | un-float / float the sidebar card (direction depends on build default) |
| `ting.content.float` / `ting.content.dock` | enable / disable floating content cards (direction depends on build default) |
| `ting.darkreader.off` | disable DarkReader web theming (when enabled at build) |

## Prefs

Set by `theme = "ting"` (`lib.ting.prefs`;
manual mode: set by hand):

```text
toolkit.legacyUserProfileCustomizations.stylesheets = true
svg.context-properties.content.enabled = true
layout.css.color-mix.enabled = true
layout.css.light-dark.enabled = true
layout.css.has-selector.enabled = true
widget.macos.titlebar-blend-mode.behind-window = true   (macOS only)
browser.tabs.inTitlebar = 0                             (windowControls = "titlebar")
browser.newtabpage.activity-stream.feeds.snippets = false  (hideNewtabFooter)
layout.css.prefers-color-scheme.content-override = 2    (darkreader.followScheme)
```

---

## Making the glass actually glass

`backdrop-filter` in Firefox blurs whatever sits *behind an element inside
the window* — results panels, the findbar, everything that overlaps the
page is glass for real. For the chrome slab to pick up what's behind the
window itself, your compositor does the blurring:

**Hyprland** (`hyprland.conf`):

```ini
decoration {
  blur {
    enabled = true
    size = 8
    passes = 3
    noise = 0.02
  }
}
# Firefox chrome is translucent → the compositor blurs behind it
windowrule = noblur, title:^(Media viewer)$
```

**KDE Plasma / KWin**: Window Rules → for `firefox` enable *Background
contrast/Blur* (Settings → Window Management → Window Rules → Appearance →
"Blur" + "Force"), and keep Plasma's blur strength up.

**GNOME**: blur is provided by the *Blur my Shell* extension; translucent
GTK CSD windows pick it up.

**macOS**: set
`widget.macos.titlebar-blend-mode.behind-window = true` (Firefox 126+,
already handled by the module) — the titlebar/toolbox blend the desktop
like native apps.

If your compositor can't blur (or you want pixel-perfect screenshots):
`ting.opaque = true` in about:config gives a solid matte theme.

## Troubleshooting

* **Nothing changed** — check the prefs above, then `about:support` →
  "Clear startup cache" and restart.
* **Transparent but no blur** — that's your compositor; see the previous
  section.
* **Window buttons overlap the URL bar** — that's the `float` mode doing
  its job; the nav bar already reserves space via padding. Tune
  `#nav-bar { padding-left/right }` via `extraCss`.
* **Sidebery looks unstyled** — check `about:policies` lists `3rdparty`
  for Sidebery's id, then restart Waterfox.
* **Right-hand sidebar** — the floating card margins are symmetric, but
  content-card padding assumes a left sidebar; flip it with `extraCss`.

## Development

All support scripts are **nushell** (no python in the tree):

```sh
nu checks/validate_ting.nu    # nix lexer, ctx contract, interpolation
                                 # scope, selector + darkreader wiring checks
nu checks/test_timepalette.nu    # smoke-test the palette engine
```

From nur-packages' root, `nix build --file . ting-chrome` renders the
composed theme and `nix fmt` formats the Nix files.

## License

MIT. Heavily inspired by the ten projects in the table above — go star them.
