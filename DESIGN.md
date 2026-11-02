# DESIGN.md — "Pixel Pink Retro Window" theme

Inspired by a Y2K / kawaii pixel-art chat window: hot-pink title bar, raspberry outlines, blush content area, chunky square buttons, bitmap font.

## 1. Principles
- Everything looks like one retro OS window with a title bar, menu bar, content area, toolbar and status bar.
- Hard edges only. No blur, no gradients, no soft shadows. `border-radius: 0`, or 2px at most.
- Thick outlines (3px) in dark raspberry on every component.
- Hard offset shadows (`box-shadow: 3px 3px 0 <raspberry>`) instead of blur.
- Pixel-crisp rendering: `image-rendering: pixelated`, `-webkit-font-smoothing: none`.
- Pure HTML + CSS. No JavaScript, no images required (emoji, Unicode and CSS shapes only).

## 2. Color tokens
| Token | Hex | Use |
|---|---|---|
| `--page` | `#FFC4D8` | Page background behind the window |
| `--title` | `#EE4B93` | Title bar, active tab, primary buttons |
| `--outline` | `#C23D7B` | All borders and hard shadows |
| `--menu` | `#FFB3CB` | Menu bar, toolbar, table headers |
| `--paper` | `#FFF1EE` | Content area, inputs, table cells |
| `--ink` | `#8A3556` | Body text |
| `--ink-soft` | `#B0708A` | Hints, muted text |
| `--hilite` | `#F0457F` | Numbers, key values, links |
| `--yellow` | `#FFD83D` | Icon badge, star, warnings |
| `--cyan` | `#33C6F2` | Secondary accent (status icon, focus ring) |
| `--danger` | `#D9304F` | Error text |
| `--btn-face` | `#FFA6C4` | Window-control buttons |

## 3. Typography
- Display and UI: **"Pixelify Sans"**, fallback `"Silkscreen"`, `"VT323"`, `monospace`.
- Numbers, tables, results: **"VT323"** or `"DotGothic16"`, fallback `monospace`.
- Title bar: 22px, letter-spacing 0.04em. Body: 16px. Table: 16px. Small hints: 13px.
- Load via a Google Fonts `@import` at the top of `style.css`, with the fallbacks above so the app still works offline.

## 4. Layout: the window
```
┌────────────────────────────────────────────┐
│ [▣ icon]  Linear Regression Calculator [_][x]│  title bar (--title)
├────────────────────────────────────────────┤
│ File  Edit  View  Help                      │  menu bar (--menu), decorative
├────────────────────────────────────────────┤
│ [Data] [Calculation] [Result]               │  tabs
│                                             │
│            content area (--paper)           │
│                                             │
├────────────────────────────────────────────┤
│ [A] [🖼] [♥] [★]      small credit text     │  toolbar (--menu)
├────────────────────────────────────────────┤
│ [badge] ▸ [ status pill: n = 5 · b = 0.8 ]  │  status bar
└────────────────────────────────────────────┘
```
- The window is centered, `max-width: 960px`, with a 3px `--outline` border and a 4px hard shadow.
- The window sits on the `--page` background with a 16px margin.
- The `[_]` and `[x]` buttons are decorative (no JS, so they do nothing).

## 5. Components
- **Title bar:** `--title` background, white text, 3px bottom border, yellow square badge on the left, two square control buttons on the right (`--btn-face`, 3px outline).
- **Menu bar:** `--menu` background, `--ink` text, 3px borders. Items spaced 16px apart, with `:hover` showing an `--ink` underline.
- **Tabs (radio):** square tabs with a 3px outline. Inactive = `--menu`, active = `--title` with white text and no bottom border. `:hover` shifts them up 1px.
- **Panels:** `--paper` background, 3px `--outline` border, 16px padding, `panel-header h2` in `--hilite`, uppercase.
- **Inputs (grid):** `--paper` background, 3px `--outline` border, radius 0, `:focus` gives a 3px `--cyan` outline and no glow.
- **Buttons (add, remove, export, predict):** `--btn-face` background, 3px outline, hard shadow 3px 3px. `:hover` uses `--menu`. `:active` moves 2px down/right and removes the shadow. Primary actions use `--title` with white text.
- **Tables (grid and calc):** 2px `--outline` cell borders, `--menu` header, `--paper` cells, zebra rows (`#FFE6EA`), totals row in `--menu` with bold text, numbers in `--hilite`.
- **Formula lines and equation:** a `--menu` block with a 3px dashed `--outline` border. The equation is large, in `--hilite`.
- **Result `<pre>`:** keep monospace, but use `--paper` background, 3px outline, `--ink` text, and `--hilite` for numbers (no dark theme).
- **Errors:** `--danger` text on `#FFE0E5` background with a 3px `--danger` border.
- **Status bar:** `--paper` pill with a 3px `--outline` border and a cyan square badge on the left. Highlight numbers with `--hilite`.
- **Scrollbars:** (webkit) 12px wide, `--menu` track, `--title` thumb with a 3px outline.

## 6. Pixel-corner trick (optional)
Stepped corners without images:
```css
.pixel-box {
  border: 3px solid var(--outline);
  box-shadow:
    -3px 0 0 -0px var(--outline),
    3px 0 0 var(--outline),
    0 -3px 0 var(--outline),
    0 3px 0 var(--outline);
  clip-path: polygon(0 3px,3px 3px,3px 0,calc(100% - 3px) 0,calc(100% - 3px) 3px,100% 3px,
                     100% calc(100% - 3px),calc(100% - 3px) calc(100% - 3px),
                     calc(100% - 3px) 100%,3px 100%,3px calc(100% - 3px),0 calc(100% - 3px));
}
```
Use only on the window, tabs and buttons. Skip it if it clips shadows badly.

## 7. Accessibility
- Keep text/background contrast at 4.5:1 or better (`--ink` on `--paper` passes; use white on `--title` only at 18px+).
- Visible `:focus-visible` outline on every input and button.
- Respect `prefers-reduced-motion` (no animations are needed anyway).
- Responsive: under 640px the window goes full-width and the tabs wrap.

## 8. Do not
- No JavaScript, no external images, no CSS frameworks.
- No rounded pills (except the status bar), no gradients, no blur.
- Do not rename form fields, routes or element ids that the server relies on.