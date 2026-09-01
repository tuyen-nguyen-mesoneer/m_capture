# mesoneer styleguide — local reference

Two sources, and they answer different questions:

1. **The official brand guidelines** — Frontify → *mesoneer Brand → Guidelines*
   (`https://mesoneer.frontify.com/d/N4GtF529pqmX/guidelines`, login required). This is
   authoritative for **colour, typography and the logo**. Every named colour below is
   copied from its Colors page; nothing here is eyeballed or mixed.
2. **Measurements from https://www.mesoneer.io** (computed styles, viewport 1440px) — for
   everything the guidelines don't specify: layout, spacing, hero composition, nav and
   footer metrics. Use these instead of re-inspecting the live site.

Update this file if either changes; both the app (`Sources/Theme.swift`) and the landing
site (`docs/index.html`) are meant to agree with it.

## Official palette (Frontify)

| Group     | Name           | Hex       | In `Theme.swift`  |
|-----------|----------------|-----------|-------------------|
| Primary   | Deep Trust     | `#191528` | `surfaceBase`     |
| Primary   | Night Indigo   | `#302355` | `surfaceRaised`   |
| Primary   | Signal Purple  | `#422982` | `accentPurple`    |
| Secondary | Lavender Ease  | `#C39CFF` | `lavenderEase`    |
| Secondary | Light Lilac    | `#D5BAFF` | `lavender`        |
| Accent    | Vibrant Coral  | `#FF6D6A` | `accent`          |
| Neutral   | White / Black / Alabaster `#FAFAFA` / Alto `#DADADA` | | |

Primary ramp (Primary 1.0 → 0.1): `#422982` `#553E8F` `#68549B` `#7B69A8` `#8E7FB4`
`#A194C1` `#B3A9CD` `#C6BFDA` `#D9D4E6` `#ECEAF3`.
Primary **tints** below 1.0: Primary 1.1 `#32245B`, Primary 1.2 `#2B2049`.
Accent ramp starts at `#FF695E` (the gradients use that value; the named swatch is
`#FF6D6A`).

**Any new shade must come off one of these ramps.** `#432A84`, `#2A1F50`, `#120D20`,
`#3A2F5E` and `#412880` were all approximations from the live site and are gone from the
app; `#120D20` survives only in the landing page's hero/footer deepening, which
replicates the live brand site's own execution.

### The three official gradients

- **Gradient 1** — 45°, `#2B2049` 10% → `#32245B` 40% → `#422982` 80%. For *highlighting*
  larger areas (sections, boxes, buttons); text on it must be white. In the app this is
  `Theme.highlightGradient`. It is **not** the general panel surface (see
  `Theme.panelGradient`, a much calmer wash on Deep Trust — painting every panel with
  Gradient 1 makes Signal Purple the whole app, the opposite of the restraint the colour
  system asks for), and it is **not** what the brand icon uses either; see below.
- **Gradient 2** — 45°, `#C39CFF` 20% → `#FF695E` 80%. Small elements only (graphic lines,
  icons), never large areas. Unused in the app so far.
- **Gradient 3** — horizontal, `#422982` → `#C39CFF` 50% → `#FF695E`. **Lines only.**

### Typography (Frontify)

- **Open Sans** is the corporate typeface, in exactly four approved styles: Regular,
  Regular Italic, SemiBold (600), Bold (700). No Light, no ExtraBold, no condensed cuts.
- **Verdana** is the digital fallback (email signatures only).
- **PolySans** is reserved *exclusively for the logo* — never for body or UI text.

The app bundles the variable roman face (`Resources/Fonts/OpenSans-Variable.ttf`, SIL OFL)
and `Theme.font` snaps any `NSFont.Weight` onto one of the three approved romans. The
italic face is not bundled because nothing in the app is italic.

### The brand icon

"m." centred in a **circle** — 18x glyph inside a 34x circle, and that proportion is
fixed. Two approved variations only: *dark* for light or neutral backgrounds, *white* for
dark, coloured or image backgrounds. Minimum clear space is one x-unit all round; minimum
100 px for digital avatars/app icons, 10 mm in print. It may not be stretched, rotated,
outlined, shadowed or recoloured.

**Take the geometry and the colours from the official asset, not from the Colors page.**
The mark predates the current gradient system and carries its own ramp, so guessing from
the palette gets both variations wrong:

| | circle | glyph |
|---|---|---|
| dark icon  | 45° bottom-left → top-right: `#191527` .21 → `#1F1933` .34 → `#302553` .57 → `#312655` .58 → `#251D3E` .67 → `#1C172D` .76 → `#191527` .83 | `#FFFFFF` |
| white icon | `#FFFFFF` | `#302655` |

(i.e. Deep Trust lifting to Night Indigo across the middle and back — **not** Gradient 1,
and the white icon's glyph is that same indigo, **not** Signal Purple.)

The "m." itself is set in **PolySans**, which is commercial and logo-only, so it must be
the real outline — never typeset in a substitute face. `Sources/Logo.swift` holds the `d`
string from Frontify's brand-icon SVG and parses it; `tools/makeicon.swift` is compiled
against that file so the app icon is the same definition. Source assets live under
Frontify → *Logo → Brand Icon* (SVG, PNG and EPS, both variations).

The icon's circle is **the one documented exception** to the square-cornered rule below.

---

## Landing-site measurements (mesoneer.io)

> All measurements at viewport **1440px**. Content edges land at **x=80 (left)**
> and **x=1360 (right)**, content width **1280px**.

## Font
- Family: **Open Sans** (the site serves "Open Sans V2"); local copy in
  `docs/assets/fonts/open-sans-latin.woff2`.

## Color palette (as applied on the landing site)

Every value below is a brand colour; **nothing on the page is off-palette any more**
(audited: no stray hex, no stray `rgb()` base). The columns that used to hold measured
approximations are noted with what replaced them.

| Role                  | Value                                     | Use                                          |
|-----------------------|-------------------------------------------|----------------------------------------------|
| Surface base / dark   | `#191528` Deep Trust                      | hero, nav, footer, code blocks               |
| Raised                | `#2B2049` Primary 1.2                     | the hero screenshot frame                    |
| Purple (solid accent) | `#422982` Signal Purple                   | solid fills/borders, glow                    |
| Purple-light          | `#553E8F` Primary 0.9                     | lighter glow, SVG stops                      |
| Lavender              | `#D5BAFF` Light Lilac                     | eyebrows, accents, badge borders             |
| Lavender (bright)     | `#C39CFF` Lavender Ease                   | the accent-bar's middle stop, big glow       |
| Accent                | `#FF6D6A` Vibrant Coral                   | the accent-bar's end stop                    |
| Brand icon            | Official asset — see "The brand icon"     | the `m.` mark                                |
| Text on dark          | `#fff`                                    | headings/body                                |
| Muted on dark         | `rgba(255,255,255,.6)`                    | footer links, secondary                      |
| Surface light         | `#ECEAF3` Primary 0.1                     | light section bg (features, install, feedback)|
| Heading on light      | `#191528` Deep Trust                      | headings on light sections                   |
| Body on light         | `rgba(25,21,40,.72)`                      | body text on light sections                  |
| Eyebrow on light      | `rgba(25,21,40,.6)`                       | eyebrows on light sections                   |
| Button hover (white)  | `#DADADA` Alto                            | primary/nav CTA hover darken                 |
| Illustration strokes  | `#8E7FB4` / `#7B69A8` Primary 0.6 / 0.7   | inline SVG art                               |

Replaced, and why — do not reintroduce these:

| Was        | Now                  | Note                                                     |
|------------|----------------------|----------------------------------------------------------|
| `#120D20`  | `#191528`            | Deep Trust *is* the brand's darkest primary; there is nothing below it, so the hero's deepening is now flat and the screenshot frame took `#2B2049` instead of being darker than the page. |
| `#1B1430`  | `#191528`            | heading on light                                          |
| `#5B556A`  | `rgba(25,21,40,.72)` | the guidelines define no body colour for light grounds beyond the neutrals, so this is Deep Trust at opacity rather than an invented grey — same result on `#ECEAF3` |
| `#6E6781`  | `rgba(25,21,40,.6)`  | as above                                                  |
| `#ECECEC`  | `#DADADA`            | Alto is the brand neutral for exactly this                |
| `#0D0A18`  | `#191528`            | code-block surface                                        |
| `#E8E2F5`  | `#ECEAF3`            | code text → Primary 0.1                                   |
| `#33265F` / `#15102A` | `#32245B` / `#191528` | node hover state                              |
| `#533AA3`  | `#553E8F`            | SVG stop → Primary 0.9                                    |
| `#9B7FD4` / `#7A5CC0` | `#8E7FB4` / `#7B69A8` | illustration strokes → Primary 0.6 / 0.7     |
| `#432A84`  | `#422982`            | Signal Purple; 22 occurrences, incl. the `rgba(67,42,132,…)` bases |
| `#412880` / `#2A2048` | official brand-icon asset | the old apple-touch tile, not the brand mark |

### Type on the page

Open Sans is served locally from `assets/fonts/open-sans-latin.woff2` as a variable face.
Its `@font-face` range is pinned to **`400 700`**, not the file's full `300 800`: the brand
approves Regular / SemiBold / Bold only, and a wider range would silently render Light or
ExtraBold for any stray `font-weight`. Only 400 / 600 / 700 are used.

### Corners on the page

Audited: the only non-zero radius left is `50%`, on the circular glow nodes and the brand
icon — circles by function, which is the documented exception. Two badge pills carried a
stray `2px`; that was mesoneer's *cookie banner*, not something to copy, and they are now 0.

## Typography scale (Open Sans)
| Role                                    | Size | Weight  | Letter-spacing     | Line-height |
|-----------------------------------------|------|---------|--------------------|-------------|
| Body                                    | 16px | 400     | normal             | 1.5 (24px)  |
| h1                                      | 56px | 700     | −0.03em (−1.68px)  | 1.15        |
| h2                                      | 40px | 700     | normal (~0)        | 1.2 (48px)  |
| Eyebrow                                 | 14px | **400** | +0.015em (~0.21px) | —           |
| (eyebrow is UPPERCASE, color `#d5baff`) |      |         |                    |             |
| Sub-label                               | 18px | 400     | normal             | 1.2         |

## Corners
**Strictly square — `border-radius: 0` everywhere** (verified: every image and
content block is 0). Buttons radius 0; the only rounding on the site is tiny 2px
on cookie-banner buttons. Keep cards, frames, screenshots, panels, badges at 0.

## Layout container
- **Full-width** sections with a **72px** horizontal padding wrapper, content
  capped at **max-width 1280px** centered.
- Landing-site implementation (single `.wrap`): `max-width:1424px; margin:0 auto;
  padding:0 72px` → content 1280, edges at x=80/1360 on a 1440 viewport.
- Responsive padding: `40px` ≤900px, `20px` ≤560px.

## Hero
- **Background** (measured from the live hero gradient image, sampled): a **flat
  `#191528` base** carrying **one soft purple glow in the upper-right** — peak
  ≈`#2f2257` (≈`#432a84` over the base) centred around **x≈89%, y≈35%**, falling
  off to the flat base before it reaches the horizontal centre. No glow on the
  left, no diagonal lightening of the top-left, and the base **deepens gently
  toward `#120d20`** at the very bottom. Impl: a single right-side
  `radial-gradient(rgba(67,42,132,.5)…)` over `linear-gradient(180deg, base → base2)`.
- Centered content, in order: eyebrow → h1 (2 lines) → lede (2 lines) → 2 buttons.
- **Eyebrow** sits ~64px below the top of the hero (≈64px below the nav), **32px
  gap to the h1**. Impl: `.hero{padding-top:64px}` + `.hero .eyebrow{margin-bottom:32px}`.
- **h1**: 56px / 700 / −0.03em / line-height 1.15, **max-width 720px** (centered)
  so it wraps to **2 lines**. (Ours forces the break with `<br>`.)
- **Lede**: **16px** / 400 / line-height 1.5 / color **`rgba(255,255,255,.9)`**,
  centered, **2 lines** — keep the copy concise. Use `text-wrap:balance`; pick a
  max-width that yields 2 lines for the copy (≈720px for our English string;
  mesoneer's German runs wider at ~1026px because the words are longer).
- Principle: **replicate mesoneer's hero exactly; only the words change.**

## Brand casing
- **"mesoneer" is always all-lowercase**, even inside an uppercased eyebrow. The
  `.eyebrow` is `text-transform:uppercase`, so wrap the wordmark in
  `<span class="lc">mesoneer</span>` (`.eyebrow .lc{text-transform:none}`) to keep
  it lowercase.

## Buttons (height was the recurring miss)
- **Primary**: bg `#fff`, text `#191528`, **16px / 600**, letter-spacing −0.01em
  (−0.16px), **padding 10px 20px**, **line-height 20px → height 40px**,
  **radius 0**, **no border, flat** (no shadow, no hover-lift). Hover: subtle
  darken (`#ececec`).
- **Secondary / ghost**: bg `rgba(255,255,255,.08)`, white text, **1px solid
  `rgba(255,255,255,.16)`** border, same metrics → height 42px (border adds 2px).
- **Solid-purple** variant (e.g. "Jobs"/CTA): bg `#432a84`, white text.
- A `.cta-row` flex container must set `align-items:center` so the primary keeps
  its 40px and isn't stretched to the ghost's 42px.

## Header / nav
- **Solid `#191528` background — NO blur, NO transparency.**
- Height **73px**, `border-bottom: 1px solid rgba(255,255,255,.2)`,
  `box-shadow: 0 4px 12px rgba(0,0,0,.08)`.
- **Three zones**: logo **left** (x=80), menu **centered** (`flex:1` +
  `justify-content:center` → centers in the gap between logo and the right group,
  *not* viewport-centered), CTA + language **right** (right edge x=1360).
- Nav links: 16px / 400 / white (`rgba(255,255,255,.9)`).
- Language switcher: 16px / 400, white; separator is a faint hairline.

## Footer
- Background `#191528` with a **purple radial glow on the right**
  (`radial-gradient(... at ~92% 40%, rgba(67,42,132,.45), transparent)`).
- **Total height ≈ 535px** (1440 viewport). Top padding **80px**, bottom padding **80px**.
- **Columns** (top): headers **white, 600, sentence-case, 16px** (margin-bottom 18px);
  links **`rgba(255,255,255,.6)`, 14px / 400** (margin-bottom 13px); column gap 72px.
- Large airy gap (~123px in our impl) between the columns and the divider.
- **Divider**: 1px, **`rgba(255,255,255,.4)`**, spans the content width (x=80→1360),
  sits at y≈348 from the footer top.
- **Below the divider**:
  - **Wordmark** "meso" / "neer." (two lines, white, bold) — **bottom-left**.
  - **Right column**: social icons on top, **© below them**.
- **Social icons**: **21px**, **20px gap**, **flush-right at x=1360**, ~41px below
  the divider. © sits ~45px below the icon top (≈24px gap after the icons),
  white 14px.
- No "internal tool / MIT / version" line — mesoneer's footer is just columns +
  wordmark + socials + ©.

## Brand assets & links
- Official `m.` brand icon: see "The brand icon" above for both variations and their
  exact colours. (The square tile that used to be documented here was the old
  apple-touch webclip, not the brand mark.)
- mesoneer AG link: `https://www.mesoneer.io/?r=0`
- Social: LinkedIn `https://www.linkedin.com/company/18715332/`,
  Facebook `https://www.facebook.com/mesoneer`.
