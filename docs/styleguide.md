# mesoneer styleguide — local reference

Design tokens measured from **https://www.mesoneer.io** (computed styles, viewport
1440px). Use this as the source of truth for the m_capture landing site
(`docs/index.html`) instead of re-inspecting the live site. Update it here if the
brand site changes.

> All measurements at viewport **1440px**. Content edges land at **x=80 (left)**
> and **x=1360 (right)**, content width **1280px**.

## Font
- Family: **Open Sans** (the site serves "Open Sans V2"); local copy in
  `docs/assets/fonts/open-sans-latin.woff2`.

## Color palette
| Token                 | Hex                                                                | Use                                            |
|-----------------------|--------------------------------------------------------------------|------------------------------------------------|
| Surface base / dark   | `#191528`                                                          | hero, nav, footer background                   |
| Deep                  | `#120d20`                                                          | gradient bottom                                |
| Raised                | `#302355`                                                          | raised containers                              |
| Purple (solid accent) | `#432a84`                                                          | solid fills/borders, glow                      |
| Purple-light          | `#533aa3`                                                          | lighter glow                                   |
| Lavender              | `#d5baff`                                                          | eyebrows, accents                              |
| Logo tile gradient    | `#412880` (bright, top-right) → `#2a2048` (dark, bottom-left), 45° | the `m.` mark                                  |
| Text on dark          | `#fff`                                                             | headings/body                                  |
| Muted on dark         | `rgba(255,255,255,.6)`                                             | footer links, secondary                        |
| Body on white         | `#121212`                                                          | deepest text (unused; see below)               |
| Surface light         | `#eceaf3`                                                          | light section bg (features, install, feedback) |
| Heading on light      | `#1b1430`                                                          | headings on light sections                     |
| Body on light         | `#5b556a`                                                          | body text on light sections                    |
| Eyebrow on light      | `#6e6781`                                                          | eyebrows on light sections                     |

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
- Official `m.` icon (apple-touch webclip): square tile, gradient
  `#412880`(top-right) → `#2a2048`(bottom-left), white `m.` glyph.
- mesoneer AG link: `https://www.mesoneer.io/?r=0`
- Social: LinkedIn `https://www.linkedin.com/company/18715332/`,
  Facebook `https://www.facebook.com/mesoneer`.
