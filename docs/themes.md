# Themes

OpenHuman Mail is themed by plain JSON files. The built-in themes (Light, Dark, Paper, Midnight, System Light, System Dark) and accents
(Blue, Iris, Pine, Graphite, System) are files in the same format as yours, and go through the same checks.

Themes colour the content: the message list, the conversation and the composer. The window chrome (toolbar, sidebar,
menus, controls) always uses the native macOS colours and materials, in every theme.

System Light and System Dark are the default. They use sRGB snapshots of macOS's semantic colors, the system font at
AppKit's sizes, a plain window-coloured canvas and the same rows as the other themes (32, 40 or 48 pt for Compact,
Default and Comfortable). With the System accent, the accent tokens follow the accent chosen in System Settings, live;
the app adjusts that colour where needed so accent text, fills and focus rings keep their contrast. Native controls
are tinted with the accent only when you choose one other than System.

Preferences saved before this default existed move once from the built-in Light and Dark themes to System Light and
System Dark. Paper, Midnight and your own themes are kept, and so is a later choice of Light or Dark.

## Where themes live

```
~/Library/Application Support/OpenHuman/Mail/Themes/            themes (*.json)
~/Library/Application Support/OpenHuman/Mail/Themes/accents/    accents (*.json)
```

The folder is watched: save a file in any editor and the app picks it up within a second, no restart. Settings ›
Appearance has **Open Folder**, **Import Theme…** (checks the file, then copies it in as `<id>.json`), **Export as
Theme…** (saves your accent, fonts, reader size and email colors as a small theme that builds on the current one),
**Reload** and **Reset**.

The built-in files are a good starting point:
`Packages/OpenHumanMailCore/Sources/MailTheme/Themes/` in the source tree. Copy one, change its `id` (ids starting
with `openhuman.` are reserved) and edit.

## A small theme

```json
{
  "format": "openhuman-theme",
  "formatVersion": 1,
  "id": "me.solar",
  "name": "Solar",
  "author": "You",
  "appearance": "light",
  "extends": "openhuman.light",
  "defaultAccent": "pine",
  "primitives": {
    "color": { "sun.990": "#FFFDF8", "sun.300": "#5A4A2A" }
  },
  "semantic": {
    "color": {
      "bg.window": "{sun.990}",
      "text.secondary": "{sun.300}"
    }
  },
  "components": {
    "row": { "bgCursor": "{bg.sunken}" }
  }
}
```

Anything a theme leaves out comes from the theme it `extends` (up to 3 levels: `me.solar` → `openhuman.light` →
`openhuman.base`). A theme with `"extends": null` gets the built-in Light or Dark values for whatever it leaves out.

## File format v1

| Key | Value |
|---|---|
| `format` | `"openhuman-theme"` or `"openhuman-accent"` |
| `formatVersion` | `1`. Files made for a newer version are refused with a message. |
| `id` | `name.name` (2–4 parts; lowercase ASCII letters, digits; hyphens after the first part). `openhuman.*` is reserved. |
| `name` | Shown in Settings, ≤ 40 characters, plain text. |
| `author` | Optional, ≤ 64 characters. |
| `appearance` | `"light"`, `"dark"` or `"any"` (an `any` theme draws in whichever slot it is picked for). |
| `extends` | A theme id, or `null`. |
| `defaultAccent` | Short accent id (`blue`, `iris`, `pine`, `graphite`, or yours). Settings › Accent overrides it. |
| `primitives.color` | Your named colors (`gray.976`, `sun.300`): lowercase, dotted, ≤ 64 characters. Only referenced, never used directly. |
| `semantic.color` | Colors by meaning: `bg.window`, `text.primary`, `border.hairline`, … plus `shadow.1`–`shadow.3` (shadows) and `bg.scrim`. |
| `typography` | `family` (`ui`, `reader`, `mono`) and `styles` (`body`, `title`, `reader`, …; see below). |
| `space`, `radius`, `border`, `density`, `motion` | Numbers and timings (see `base.json`). |
| `components` | Per-control tokens, e.g. `row.unreadDot`, `palette.width`, `toast.bg`. |
| `reader` | `emailColors` (`adaptWhenSafe`, `alwaysOriginal`, `alwaysAdapt`), `maxImageWidth` (`"100%"`), `quoteBorder`, `designedEmailCard`. |

The complete list of tokens, their types and allowed ranges is
`Packages/OpenHumanMailCore/Sources/MailTheme/Schema/tokens.v1.json`.

### Accent files

```json
{
  "format": "openhuman-accent",
  "formatVersion": 1,
  "id": "me.accent.sunset",
  "name": "Sunset",
  "primitives": { "color": { "sunset.500": "#C2410C", "white": "#FFFFFF" } },
  "light": { "accent.fill": "{sunset.500}", "accent.fillHover": "#A8380A", "accent.text": "#B23C0B",
             "accent.subtle": "#FDEEE6", "accent.onFill": "{white}", "accent.ring": "{sunset.500}" },
  "dark":  { "accent.fill": "#C2410C", "accent.fillHover": "#D24A12", "accent.text": "#F59E6B",
             "accent.subtle": "#3A2216", "accent.onFill": "#FFFFFF", "accent.ring": "#F08A4B" }
}
```

The accent's short id is the last part of its `id` (`sunset`). A user accent cannot replace a built-in one with the
same short id.

## Values

- **Colors**: `#RRGGBB`, `#RRGGBBAA`, or `rgba(r,g,b,a)` with whole numbers 0–255 and `a` from 0 to 1. Nothing else:
  no color names, `url(`, `var(`, `calc(` or other CSS.
- **References**: `{name}` points at a primitive (`{sun.300}`) or another token of the same kind (`{bg.sunken}`,
  `{radius.lg}`, `{shadow.2}`). Chains may be at most 8 long; loops are refused.
- **Shadows**: up to 3 layers of `x y blur spread color`, separated by commas: `0 1 2 0 rgba(17,20,26,0.06), 0 4 12 0 #11141A10`.
- **Typography styles**: `{ "size": 13, "lineHeight": 18, "weight": 400, "trackingEm": 0, "numerals": "tabular",
  "family": "ui" }`; any field may be left out to keep the parent's. Size 9–32, line height between size and 2 × size,
  weight 100–900. Tracking applies only to non-system fonts.
- **Fonts**: `"system"`, `"system-serif"` (New York), `"system-rounded"`, `"system-mono"`, or the family name of a
  font installed on your Mac (letters, digits, spaces, hyphens). Missing fonts fall back to the system font with a
  note in Settings; the app never downloads fonts.
- **Numbers** outside their range are clamped (radius 0–24, spacing 0–96, animation durations 0–400 ms, …) and
  noted.
- **Motion**: `{ "duration": 100, "easing": "cubic-bezier(0.2,0,0,1)" }` or `"easing": "linear"`.

## What the app checks

Theme files are treated as untrusted input:

- **Refused** (not loaded, listed in Settings with the reason): larger than 64 KB; not UTF-8 JSON (comments and
  trailing commas are not JSON); nested deeper than 16 levels; more than 2,000 keys; a string longer than 200
  characters; unknown `format`; `formatVersion` other than 1; a bad or reserved `id`; anything that looks like code
  in a value (CSS functions, markup, `;`, quotes, backslashes, URLs); reference loops or chains longer than 8;
  `extends` loops or more than 3 levels; `text.primary` on `bg.window` below 3:1 contrast.
- **Loaded with a warning**: unknown keys (ignored), wrong types or unparseable values (the parent's value is used),
  clamped numbers, missing parents or accents, missing fonts, and every contrast pair below its WCAG target
  (4.5:1 for text, 3:1 for focus rings, control borders and the unread dot).
- Values reach the email reader only as CSS the app writes itself from the checked values; a theme cannot add CSS
  or markup to the reader.

Settings shows each problem as `file.json: semantic.color.text.secondary: 2.1:1 on bg.window (needs 4.5:1) —
loaded with warning`. If the theme you are using breaks while you edit it, the app keeps showing its last valid
version until you fix it.
