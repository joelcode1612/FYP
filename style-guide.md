# Sitewise — UI Design System Specification

> **Purpose.** This document is the single source of truth for generating new screens. Treat every value as a hard constraint. Do not invent spacing, colour, radius, or type values that are not listed here.
>
> **Provenance.** All values are extracted from the live implementation: `fyp_jaspr_web/web/styles.css` (`:root` token block and component rules) and `fyp_mobile_app/lib/core/theme/sitewise_theme.dart`. Where the web and mobile registers differ, both are stated. Nothing here is estimated.

---

## 1. Layout & Structural Constants

### 1.1 Target platform

- **Primary target: Web desktop, responsive down to mobile browser.** Build for a 1440px desktop viewport first, then reflow at the documented breakpoints.
- **Secondary target: Mobile app (iOS/Android, Flutter Material 3).** The mobile register uses the same colour and spacing tokens but a different shell (top app bar + bottom navigation bar).
- **Do not design for tablet as a distinct layout.** Tablets receive the desktop layout until the 900px breakpoint, then the mobile shell.
- **Minimum supported width: 380px.**

### 1.2 Breakpoint ladder

Apply these breakpoints exactly. Do not introduce new ones.

| Breakpoint | Behaviour |
|---|---|
| `≤1100px` | Hero grid collapses to one column. Four-column grids become two columns. |
| `≤1050px` | Three-column and asymmetric dashboard grids collapse to one column. KPI row becomes two columns. |
| `≤900px` | Desktop navigation is replaced by a burger button and off-canvas drawer. Marketing nav and footer grid collapse to one column. |
| `≤760px` | Secondary two-column content splits stack. |
| `≤640px` | Section padding drops from 84px to 56px. All two-, three- and four-column grids become one column. Display type steps down. |
| `≤620px` | Page gutter drops from 32px to 20px. |
| `≤380px` | Page gutter drops from 20px to 14px. |

### 1.3 Container widths

- The **content band** is the canonical container: `max-width: 1424px`, centred, with `32px` inline padding. This equals a `1360px` content measure plus one gutter on each side.
- **All page containers must share this width.** Marketing pages, dashboards, and the navigation pill must all align to the same left and right edge.
- Auth and marketing two-column layouts use a narrower cap of `1280px`.
- A standalone form must not exceed `720px`. A login/credential card must not exceed `420px`.
- A modal dialog must not exceed `640px` (default `420px`).
- A full-page shell may occupy up to `1440px`.

### 1.4 Page gutters

- Horizontal page gutter is `32px` on desktop.
- Reduce to `20px` at `≤620px` and `14px` at `≤380px`.
- Never apply per-component horizontal padding to simulate a gutter. The gutter is a single global value.

### 1.5 Persistent structural heights

| Element | Height / width |
|---|---|
| Top navigation pill | `min-height: 58px`, fixed to the top of the viewport at `14px` offset, horizontally centred, width `min(1424px, 100% − 28px)`. |
| Shell top padding | `86px` — reserves the pill's height plus both offsets. |
| Marketing masthead | `72px` tall, sticky to the top, full-bleed with `24px` inner padding. |
| Anchor scroll offset | `88px` — anchored sections must never hide under the sticky header. |
| Sidebar (mobile drawer only) | `260px` wide, capped at `84vw`. Slides in from the left. |
| Burger button | `40 × 40px`. |
| Footer | Top padding `48px`, bottom padding `32px`, three-column grid. |
| Icon button | `38 × 38px` circle. |
| Brand mark | `32 × 32px`, radius `10px`. |

**Critical structural rule:** the desktop shell has **no persistent sidebar**. Primary navigation is a floating, fixed, pill-shaped bar at the top of the viewport. A sidebar exists only below 900px, as an off-canvas drawer.

### 1.6 Grid rules

- Two-column grid: `2` equal columns, `16px` gap.
- Three-column grid: `3` equal columns, `16px` gap.
- Four-column grid (KPI row): `4` equal columns, `16px` gap, `24px` bottom margin.
- Asymmetric dashboard grid: `1.55fr` left / `0.75fr` right, right column minimum `300px`, `16px` gap.
- Marketing hero grid: `1.02fr` / `0.98fr`, `46px` gap. Collapses to `30px` gap at `≤1050px`.
- Footer grid: `1.4fr 1fr 1fr`, `32px` gap.
- Form field grid: `2` equal columns, `16px` gap.
- **All grid tracks must use `minmax(0, 1fr)`**, never a bare `1fr`. A bare `1fr` track refuses to shrink below its content and forces page overflow.

### 1.7 Spacing scale

Use only these five steps. No exceptions.

| Token | Value |
|---|---|
| `xs` | `4px` |
| `sm` | `8px` |
| `md` | `16px` |
| `lg` | `24px` |
| `xl` | `32px` |

Sub-steps permitted only inside compact components: `2px`, `6px`, `10px`, `14px` for internal gaps and paddings.

### 1.8 Section and card spacing

- Full-width section bands use `84px` vertical padding, reduced to `56px` at `≤640px`.
- Standard card padding: `20px`.
- Dense/flat card padding: `16px`.
- Panel padding: `22px` with `14px` internal gap.
- Metric card padding: `18px 20px`.
- Stat block padding: `12px`.
- Dark/contrast card padding: `24px`.
- Page header bottom margin: `24px`.
- Vertical rhythm between stacked sections: `32px`.

---

## 2. Color Palette

### 2.1 Light theme (default)

| Role | Value |
|---|---|
| **Primary / Action** | `#1D4ED8` |
| **Primary hover / Accent** | `#3B82F6` |
| **Canvas / Background** | `#E8EEF6` |
| **Paper (second canvas)** | `#F4F7FB` |
| **Surface / Card** | `#FFFFFF` |
| **Alt surface** | `#FAFBFC` |
| **Ink (headings, dark fills)** | `#0B0F19` |
| **Body text** | `#1E293B` |
| **Muted / secondary text** | `#64748B` |
| **Overline text (small caps)** | `#6B7280` |
| **Stone (borders/icons only)** | `#94A3B8` |
| **Border / divider** | `#E7E8EA` |
| **Strong border** | `#CBD5E1` |
| **Success** | `#0D9488` |
| **Success text** | `#0F766E` |
| **Success wash** | `#D1FAE5` |
| **Warning** | `#B45309` |
| **Warning wash** | `#FEF3C7` |
| **Danger / Error** | `#DC2626` |
| **Danger wash** | `#FEE2E2` |
| **Info / geospatial wash** | `#DBEAFE` |
| **Info / geospatial border** | `#BFDBFE` |
| **Neutral wash** | `#F4F7FB` |
| **Scrim** | `rgba(15, 23, 42, 0.45)` |

### 2.2 Dark theme (authenticated app shell only)

| Role | Value |
|---|---|
| Background | `#090909` |
| Paper | `#141414` |
| Surface | `#181818` |
| Alt surface | `#212121` |
| Ink | `#F7F7F7` |
| Body text | `#DFE0E4` |
| Muted | `#989BA4` |
| Border | `#303036` |
| Strong border | `#3D3F45` |
| Action | `#1683FC` |
| Accent | `#4DA3FF` |
| Success | `#17B3A6` |
| Success text | `#86E4A2` |
| Warning | `#FFC277` |
| Danger | `#FF8787` |
| Scrim | `rgba(0, 0, 0, 0.68)` |

### 2.3 Colour rules

- **Use exactly one accent family: blue.** Never introduce a second accent hue.
- **Never use `#94A3B8` for text.** It measures 2.55:1 on white and fails WCAG AA. It is a border and icon token only. Small text uses `#6B7280` (4.82:1).
- **Never use `#0D9488` directly for small text.** Use `#0F766E` (5.40:1) instead.
- **Semantic colours always appear as a wash background paired with its dark foreground.** Never place a semantic hue on an unrelated background.
- **Never flood a large area with the primary blue.** Sanctioned solid fills are: the primary button, the active nav pill, the brand mark, and the destructive confirm button.
- **Do not use the primary blue for decoration.** Blue means "interactive".

---

## 3. Typography Hierarchy

### 3.1 Font family

- **One family for everything: Archivo.** Weights 400, 500, 600, 700, 800, 900.
- Fallback stack: `system-ui, -apple-system, "Segoe UI", sans-serif`.
- Icons use Material Symbols Outlined at `20px` (variants: `16px` small, `24px` large).
- **Do not pair a second typeface.** Headings are distinguished by weight (800–900) and negative tracking, not by family.

### 3.2 Base rules

- Body text is `15px` with `1.55` line-height.
- All headings use `line-height: 1.12` and `letter-spacing: -0.02em` unless a specific size overrides it.
- All headings have zero margin. Spacing between elements is owned by layout gaps, not by margins.
- Apply negative tracking that scales with size: `-0.048em` at hero size, `-1.6px` at 46px, `-1px` at 34px, `-0.02em` at 22–26px.

### 3.3 Type scale

| Role | Size | Weight | Line-height | Tracking | Colour |
|---|---|---|---|---|---|
| Hero headline (H1) | `clamp(32px, 4.1vw, 54px)` | 900 | 1.03 | −0.048em | Ink |
| Display | `46px` → `32px` at ≤640px | 800 | 1.06 | −1.6px | Ink |
| Page title | `26px` | 800 | 1.2 | −0.02em | Ink |
| Section title (H2) | `34px` | 700 | 1.12 | −1px | Ink |
| Card title (H3) | `22px` | 900 | 1.12 | −0.02em | Ink |
| Panel heading | `18px` | 800 | 1.12 | −0.03em | Ink |
| Card heading (H4) | `17px` | 800 | 1.2 | −0.025em | Ink |
| Sub-title | `16px` | 800 | 1.12 | −0.02em | Ink |
| Lead paragraph | `16px` | 400 | 1.65 | 0 | Body text |
| Body | `14px` | 400 | 1.6 | 0 | Body text |
| Table cell | `12.5px` | 400 | 1.5 | 0 | Ink |
| Small / caption | `12.5px` | 400 | 1.55 | 0 | Muted |
| Tiny | `11px` | 400 | 1.5 | 0 | Muted |
| Eyebrow | `11px` | 900 | 1.2 | +0.12em, uppercase | Action |
| Overline | `10px` | 700 | 1.2 | +0.9px, uppercase | Overline text |
| Metric / KPI value | `30px` | 900 | 1 | −0.045em | Ink |
| Brand wordmark | `15.5px` | 900 | 1.1 | −0.04em | Ink |

### 3.4 Weight as semantic signal

- `900` — hero and display headings, card titles, metric values, button labels, eyebrow labels, brand wordmark.
- `800` — page titles, panel headings, nav links, badges, status pills.
- `700` — section titles, table headers, active nav items, form labels.
- `500` — inactive navigation items.
- `400` — all body prose.

### 3.5 Typography rules

- **Reserve uppercase and positive tracking exclusively for micro-labels:** eyebrow, overline, table header, sidebar role, metric card label.
- **Never letter-space body copy upward. Never set prose in uppercase.**
- **Never use a font size that is not on the scale above.**
- Measure limits: page description `62ch`, empty-state body `58ch`, hero lead `60ch`, hero headline `22ch`, stat note `80ch`.

---

## 4. Component Styling Rules

### 4.1 Buttons

**Base geometry (all variants):**

- Shape: **full pill. Border-radius `999px`.**
- Padding: `12px` vertical, `19px` horizontal.
- Font: `13px`, weight `900`, line-height `1`, no wrapping.
- Border: `1px solid rgba(15, 23, 42, 0.12)`.
- Default background: `rgba(255, 255, 255, 0.92)`.
- Default text: Ink `#0B0F19`.
- Icon gap: `8px`. Leading icons are `16px`.
- Computed height: approximately `39px`.
- Transition: `transform`, `box-shadow`, `background`, `border-color` at `0.2s`.

**Hover state (all variants):** lift by `translateY(-2px)` and add `box-shadow: 0 10px 24px rgba(15, 23, 42, 0.1)`.
**Active state (all variants):** `scale(0.97)`.

| Variant | Rest | Hover |
|---|---|---|
| **Primary** | Ink fill `#0B0F19`, white label, ink border | Background and border shift to Action `#1D4ED8` |
| **Accent** | Action fill `#1D4ED8`, white label, `box-shadow: 0 8px 22px rgba(29, 78, 216, 0.22)` | Background and border shift to `#3B82F6` |
| **Secondary** | White surface `rgba(255,255,255,0.92)`, ink label, hairline border | Border and label shift to Action `#1D4ED8`, no fill change |
| **Ghost** | Transparent, `#64748B` label, strong border `#CBD5E1`, padding `9px 15px`, `12px`/`800` | Label and border shift to Ink, white fill |
| **Danger outline** | White surface, `#DC2626` label, border `rgba(220, 38, 38, 0.28)` | Border becomes `#DC2626`, fill becomes `#FEE2E2` |
| **CTA (full width)** | Width `100%`, padding `15px 24px`, `14.5px` | Inherits its base variant |

**Size modifiers:** small = `8px 14px` padding, `12px` text, `6px` gap. Large = `15px 24px` padding, `14.5px` text.

**Disabled:** `opacity: 0.5`, `cursor: not-allowed`, no pointer events.

**Button rules:**
- **Buttons must always be pills.** Never use a rounded rectangle for a button.
- **Buttons must never have a drop shadow at rest** (the accent variant is the single exception).
- Group buttons in rows with a `12px` gap and allow wrapping.
- Minimum touch target on mobile is `48 × 48px`. Never shrink a mobile button to match the web's ~39px height.

### 4.2 Input fields

Two registers exist. Use the correct one for the context.

**Inline / search input:**

- Border: `1px solid #E7E8EA`.
- Border-radius: `10px`.
- Padding: `10px 12px`.
- Font: `14px`.
- Background: **`#E8EEF6` (canvas), not white.** Inputs read as inset.
- Text colour: Ink.
- Focus: `2px solid #1D4ED8` outline with `0` offset.

**Form field input (labels, hints, errors):**

- Height: `40px`, full width.
- Padding: `0 12px`.
- Background: `#FFFFFF`.
- Border: `1px solid #CBD5E1`.
- Border-radius: `10px`.
- Font: `13.5px`, Ink.
- Focus: border becomes `#1D4ED8` and a `3px` ring of `#DBEAFE` is added. No outline.
- Label: `12.5px`, weight `700`, Ink, `6px` gap above the field.
- Hint: `11.5px`, `#64748B`.
- Error text: `11.5px`, weight `700`, `#DC2626`.
- Invalid field: border becomes `#DC2626`.
- Checkbox / radio: `14 × 14px`, radius `4px`, accent colour `#1D4ED8`.

**Input rules:**
- **Inputs must always have a `10px` radius.** Never a pill, never square.
- **Every input must have a visible focus ring.** Never remove focus styling.
- **Every input must have an associated label.** Placeholder-only fields are not permitted.

### 4.3 Cards and containers

| Component | Specification |
|---|---|
| **Card** | Background `#FFFFFF`, border `1px solid #E7E8EA`, radius `16px`, padding `20px`, `box-shadow: 0 12px 32px rgba(15, 23, 42, 0.05)`. |
| **Flat card** | Same but radius `12px`, padding `16px`, **no shadow**. |
| **Panel** | Background `#FFFFFF`, border `1px solid #E7E8EA`, radius `16px`, padding `22px`, internal gap `14px`, `box-shadow: 0 12px 32px rgba(15, 23, 42, 0.05)`. |
| **Metric card** | Background `#FFFFFF`, border `1px solid #E7E8EA`, radius `16px`, padding `18px 20px`, `box-shadow: 0 12px 32px rgba(15, 23, 42, 0.05)`. Hover: border becomes `#CBD5E1`. |
| **Stat block** | Background `#F8FAFC`, border `1px solid #E7E8EA`, radius `12px`, padding `12px`. |
| **Contrast card** | Background `#0B0F19`, border `1px solid #0B0F19`, radius `16px`, padding `24px`, white text, secondary copy at `rgba(255,255,255,0.62)`. |
| **Empty state** | Background `#FFFFFF`, `1px dashed #CBD5E1`, radius `16px`, padding `40px 28px`, centred. |
| **Dialog** | Background `#FFFFFF`, border `1px solid #E7E8EA`, radius `16px`, `box-shadow: 0 24px 64px rgba(15, 23, 42, 0.25)`, max-width `420px` (wide `640px`), max-height `60dvh`. |
| **Menu / popover** | Background `#FFFFFF`, border `1px solid #E7E8EA`, radius `14px`, `box-shadow: 0 16px 48px rgba(15, 23, 42, 0.22)`, min-width `240px`, padding `8px`. |

**Metric card internal structure:** label (`11px`, `900`, `+0.1em`, uppercase, muted) → value (`30px`, `900`, `−0.045em`, ink, `6px` above) → note (`12.5px`, muted, `4px` above).

**Card rules:**
- **Cards must always have a `1px` border.** The border, not the shadow, is the primary separation device.
- **Cards must never have a heavy shadow.** Only the single soft `0 12px 32px rgba(15,23,42,0.05)` recipe is permitted.
- **Never use a shadow without a border.**
- **Never use a border thicker than `1px`**, except the `2px` focus ring and the `1.6px` mobile focused-input border.
- Drop the bottom border on the last table row so a table never double-borders inside its panel.

### 4.4 Navigation

**Desktop nav pill:**

- Fixed to the top of the viewport, `14px` from the top, horizontally centred.
- Width `min(1424px, 100% − 28px)`, `min-height: 58px`.
- Background `rgba(255, 255, 255, 0.86)`, border `1px solid rgba(15, 23, 42, 0.08)`.
- Radius `999px`. Padding `6px 8px 6px 10px`.
- Backdrop blur `16px` with `saturate(150%)`.
- Two-stage shadow: `0 1px 2px rgba(15,23,42,0.04), 0 12px 32px rgba(15,23,42,0.08)`.

**Nav link:** padding `9px 14px`, radius `999px`, `13px`, weight `800`, colour `#46536B`, `6px` icon gap, no icons in the desktop link row. Hover: background `rgba(15,23,42,0.05)`, colour Ink.
**Active nav link:** solid Ink fill `#0B0F19`, white label, pill radius.

**Sidebar (mobile drawer only, ≤900px):**

- Width `min(260px, 84vw)`, fixed, full height, slides in from the left over a scrim.
- Background `#FFFFFF`, `1px` right border, `box-shadow: 0 16px 48px rgba(15, 23, 42, 0.22)`.
- Nav item: full width, `12px` icon gap, padding `11px 12px`, radius `10px`, `14px`, weight `500`, Ink.
- Active nav item: background `#DBEAFE`, colour `#1D4ED8`, weight `700`.
- Role label: `11px`, weight `700`, `+1.2px`, uppercase, `#6B7280`.

### 4.5 Status, badges, and chips

- **Status pill:** inline-flex, `6px` gap, padding `4px 11px`, radius `999px`, `11.5px`, weight `800`, with a `6px` circular dot in the current text colour.
- **Badge:** same pill geometry, padding `3px 10px`, `11px`, weight `800`, no dot.
- **Filter chip:** padding `4px 8px`, radius `999px`, `1px solid #E7E8EA` border, background `#DBEAFE`, colour `#1D4ED8`, `12px`, weight `600`.
- **Dot:** `7 × 7px` circle.

**Tone pairings — always a wash background with its dark foreground:**

| Tone | Background | Foreground |
|---|---|---|
| Neutral | `#F4F7FB` | `#64748B` |
| Info / Action | `#DBEAFE` | `#1D4ED8` |
| Success | `#D1FAE5` | `#0F766E` |
| Warning | `#FEF3C7` | `#B45309` |
| Danger | `#FEE2E2` | `#DC2626` |

**Status must always be a pill.** Never a square badge.

### 4.6 Data tables

- Cell font `12.5px`. Row padding `10px 12px`. `1px` bottom border on every row except the last.
- Header: `10.5px`, weight `700`, `+0.1em`, uppercase, `#64748B`, background `#F8FAFC`, `1px` bottom border.
- Cells align to the top. Wrap wide tables in a horizontal scroll container.

### 4.7 Icon buttons and avatars

- **Icon button:** `38 × 38px`, **full circle**, `1px solid rgba(15, 23, 42, 0.08)` border, white background, colour `#46536B`, icon `20px`. Hover: background `#F1F5F9`, border `#CDDCFA`, colour Ink.
- **Brand mark:** `32 × 32px`, radius `10px`, dark gradient fill (`#0B0F19` → `#1E293B`), `1px` border `rgba(59, 130, 246, 0.3)`, white glyph.
- **Burger button:** `40 × 40px`, radius `10px`, `1px` border, white background.

### 4.8 Elevation and depth

| Use | Shadow |
|---|---|
| Card / panel / metric card | `0 12px 32px rgba(15, 23, 42, 0.05)` |
| Large surface | `0 24px 80px rgba(15, 23, 42, 0.08)` |
| Dialog | `0 24px 64px rgba(15, 23, 42, 0.25)` |
| Menu / popover / drawer | `0 16px 48px rgba(15, 23, 42, 0.22)` |
| Button hover | `0 10px 24px rgba(15, 23, 42, 0.1)` |
| Accent button at rest | `0 8px 22px rgba(29, 78, 216, 0.22)` |

**Elevation rules:**
- **Never add a shadow to a button, app bar, or navigation bar at rest.**
- **Never use frosted glass except on the top navigation pill**, which is the single sanctioned backdrop-blur surface.
- Overlays are opaque surfaces over a `rgba(15, 23, 42, 0.45)` scrim. No blur on scrims.

### 4.9 Radius ladder

| Value | Applied to |
|---|---|
| `999px` | All buttons, pills, badges, chips, nav links, avatars, nav pill |
| `20px` | Large containers, mobile bottom-sheet top corners, chips (mobile) |
| `16px` | Cards, panels, dialogs, contrast cards, empty states |
| `14px` | Menus and popovers |
| `12px` | Flat cards, stat blocks, icon tiles |
| `10px` | Inputs, icon buttons, nav items, brand mark, burger |
| `8px` | Small links, menu items |
| `4px` | Focus ring, progress bars, checkboxes |

**Never invent a radius outside this ladder.**

### 4.10 Focus, hover, and interaction states

- **Focus visible:** `2px solid #1D4ED8` outline with `2px` offset and `4px` radius. Inputs use `0` offset.
- **Hover on neutral surfaces:** background `#E8EEF6` or `rgba(15, 23, 42, 0.05)`.
- **Hover on selected/active surfaces:** background `#DBEAFE`.
- **Disabled:** `opacity: 0.5`, `cursor: not-allowed`, pointer events off.
- **Selected card:** `2px solid #1D4ED8` outline with `2px` offset.

### 4.11 Score and progress colour ramp

Any 0–100 score must use this ramp:

| Score | Colour |
|---|---|
| ≥ 75 | `#0D9488` (success) |
| ≥ 55 | `#1D4ED8` (action) |
| ≥ 40 | `#B45309` (warning) |
| < 40 | `#DC2626` (danger) |

Progress bar: track `8px` tall, radius `4px`, background `#F4F7FB`; fill radius `4px`, background `#1D4ED8`.

---

## 5. Non-Negotiable Rules for Generated Screens

1. **Use only the five spacing steps** (`4 / 8 / 16 / 24 / 32px`) for layout rhythm. Never invent `13px`, `18px`, or `30px` rhythms.
2. **Use only the radius ladder.** Buttons are always pills; cards are always `16px`.
3. **Every surface gets a `1px` border.** Shadows are secondary and use only the documented recipes.
4. **One typeface (Archivo).** Differentiate headings by weight and negative tracking only.
5. **One accent colour (blue `#1D4ED8`).** Blue means interactive, never decorative.
6. **Semantic colours appear only as wash + dark foreground pairs.**
7. **Never use `#94A3B8` for text.** Borders and icons only.
8. **The desktop shell has no sidebar.** Navigation is a floating pill at the top.
9. **All containers share the same `1424px` content band.** No page invents its own width.
10. **Interactive elements must be at least `44px` tall on web and `48px` on mobile**, with a visible `2px` focus ring.
11. **Never use uppercase or positive tracking on prose.** Micro-labels only.
12. **Never assume photography.** Visuals are gradients, grids, map geometry, and icons. Do not place photographic placeholders.
13. **Respect the breakpoint ladder** (`1100 / 1050 / 900 / 760 / 640 / 620 / 380px`). Do not add new breakpoints.
14. **Every form field has a visible label, a `10px` radius, and a focus ring.**
