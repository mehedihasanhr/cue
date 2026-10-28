# 9. Screen Studio design tokens

Screen Studio 4.0.1's look, measured from its app bundle and from pixels in its editor, so Cue Studio can match the feel. Captured 2026-10-28. Layout and flows are in [08-ui-reference.md](08-ui-reference.md).

**How these were measured**
- The editor is an Electron app built with React and styled-components, then obfuscated.
- Its theme colours are computed at run time, so most colours below are **sampled pixels** from a screenshot of a 2× Retina window.
- Sizes are in points, which equal CSS px here.
- Values written as "~" are read off the screenshot, not found in code.

**What we may and may not use.** The numbers below are a style to match. The **asset files are not ours**: wallpapers, cursor SVGs, device PNGs, music and the icon font belong to Screen Studio, and some wallpapers belong to Apple or Raycast. Cue draws or commissions its own, described in the asset sections.

## Colour (dark)

| Role | Value | Cue Studio today |
|---|---|---|
| Window ground (title bar, canvas, tab column, transport, timeline) | `#08090C` | `Surface.seam` `0x0B` |
| Settings card | `#121419` | `Surface.panel` `0x17` |
| Field at rest (button, unchosen pill) | `#181A1F` | `Surface.field` `0x23` |
| Reset button, disabled | `#15171C`, text faint | `SliderResetButton` |
| Chosen pill | `#24262A` fill, with a `#4C4A6D` 1 pt edge (accent-tinted) | `Palette.raised` `0x2C` and `strokeStrong` |
| Hairline under the title bar | `#1B1E26` | `Surface.hairline` |
| Accent (Export, set part of a slider) | `#4930EC` | Cue blue `#0E4FEC` (kept) |
| Slider knob | `#9E91F3`: the accent mixed about 45% toward white | accent plus 25% white |
| Unset part of a slider track | `#2A2C30` | `Palette.track` |
| Clip on the timeline | `#BA8430` at the top to `#8D6424` at the bottom (a vertical gradient) | amber `#BC8430`, flat |
| Zoom on the timeline | `#887BE7` at the top to `#3A21E2` | Cue blue |
| Floating tool palette | `#191B20` | `Surface.floating` |
| Text on the title bar | white | `ink` |
| Labels | ~`#E6E6E8` | `inkSoft` |
| Values and disabled text | ~`#636569` | `inkFaint` |

The code also contains one gradient used as accent decoration: `linear-gradient(135deg, #9D8BFF, #4D2FF5)`.

## Type

- **UI font:** the system font. CSS asks for `-apple-system, system-ui`, which is SF Pro. The bundle also contains Geist Mono, Instrument Serif and Playfair Display, but those are caption and text fonts, not UI fonts. Icons come from a private icon font, "sicons", in three weights.
- **Sizes:**

| Use | Size |
|---|---|
| Section heading ("Background", "Padding") | ~14 pt, regular to medium, white |
| Control labels and pill text | ~14 pt |
| Window title | ~14 pt, extension dimmed |
| Small facts | 12–13 px (`13px` ×6, `12px` ×2 in code) |
| Badges | 10–11 px |

- **Letter-spacing:** 0.3–0.5 px on small capitals only.
- **Weights:** 600 is the bold (×11); 500 is the medium.
- **Hierarchy comes from colour, not size.** Headings and labels are almost the same size. The heading is white; the value or disabled state is grey.

## Spacing and size

| Thing | Value |
|---|---|
| Title bar height | 60 (hairline at y = 59) |
| Export button | 36 high, ~118 wide, radius ~8 |
| Settings card | 360 wide; 14 from the window's right edge; 16 below the title bar; radius ~14 |
| Sidebar padding (in code) | `--sidebar-padding-x: 24px`, `--sidebar-padding-y: 32px` |
| Tab column | ~48 wide, on the window ground; icons ~20 |
| Pill (segmented choice) | 32 high, radius ~8, gap ~6 |
| Full-width button ("Pick random wallpaper") | 36 high |
| Slider | label line, ~12 gap, then the track row; knob ~18; track 3; Reset ~32 high beside it |
| Space between slider groups | ~40 from one label to the next |
| Wallpaper thumbnails | 8 to a row, ~36 square, gap ~5, radius ~6 |
| Transport row | ~44 high, on the window ground; play is an outlined circle ~24 |
| Timeline track | **48 high**, 12 apart; ruler ~44 |
| Radii in code | 4 (×14), 10 (×14), 50% (×10), 100 px pills (×8), 8, 6, 16, 20 |
| Paddings in code | `6px 12px` and `2px 8px` (chips), `4px 8px`, `12px`, `20px`, `0 24px` |
| Gaps in code | 2, 4, 8, 10, 20 |
| Motion | `0.2s all` is the default (×7); opacity 0.125–0.25 s; hover background 0.075–0.1 s |
| Glass | `backdrop-filter: blur(10–20px) saturate(180%)`; glass tint `rgba(255,255,255,0.07)` |
| Shadows | `3px 3px 10px 4px #0004` (popovers), `0 0 24px rgba(0,0,0,.5)` |

## Hierarchy

1. **Export** is the only saturated fill in the window.
2. The **set part of a slider and its knob** are the only other accent marks.
3. The **chosen pill** is a lighter field with an accent-tinted edge. Unchosen pills are bare words on a slightly lighter field.
4. **Section headings** are white text with no icon. A section is told apart by space (~40), not by rules.
5. **Values are not written** next to sliders. Cue shows them small and grey, which is better and we keep it.
6. **Timeline blocks** are solid, bright and gradient-lit, with a two-line label: the kind ("Clip", "Zoom") faint on top, and the facts ("52s · 1×", "2× · Auto") bold under it.

## Backgrounds (inventory, not for reuse)

There are 9 packs and 182 images.

| Pack | Images | Size | What they look like |
|---|---|---|---|
| Energy | 23 | 2000² | saturated flowing waves, pink, orange, cyan |
| Glassmorphism | 10 | 4096×2342 | glossy glass ribbons on pale or blue grounds |
| Iridescent | 17 | 2000² | pale pearl gradients |
| Midnight | 18 | 2000² | monochrome dunes, black to grey |
| Radiant | 20 | 2000² | soft dusk waves |
| Raycast | 31 | 5120×2880 | Raycast's own wallpapers |
| Spring | 24 | 2000² | teal, mint and coral waves |
| Sunset | 21 | 2000² | orange and red dunes |
| macOS | 18 | 2000×1949 | Apple's wallpapers |

The picker also offers:
- a favourites ★ row
- Gradient (presets plus random), Color, your own Image, and Unsplash search
- Background blur
- "Pick random wallpaper"

**For Cue:** draw our own packs procedurally in BackgroundKit, as Cue already does for gradients and moving backgrounds:
- **wave fields** like Energy, Spring, Sunset and Radiant, made of layered sine ribbons with soft shading
- **monochrome dunes**
- **pearl gradients**
- **glass ribbons**

Generated, they cost nothing to ship, scale to any size and belong to us. Add "use my macOS wallpaper" as an option rather than shipping Apple's images.

## Cursors (inventory, not for reuse)

**Sets:**

| Set | What's in it |
|---|---|
| `macos` and `macos-tahoe` | 42 shapes each, the full system list: pointer, pointing hand, I-beam (4 kinds), open and closed hand, move, all 16 resize directions, crosshair, cell, copy, alias, not allowed, help, context menu, beach ball, screenshot selection, zoom in and out |
| `touch` | one dot for iOS |
| `halloween` | 8 pointers |
| `custom-1` … `custom-20` | 1–13 shapes each, mostly pointer and pointing-hand variants |

There is also a Figma pointer PNG.

**Naming.** Each file is `<shape>-<n>__<hotX>-<hotY>.svg`: the hotspot is part of the file name, in percent of the image. For example `pointer-1__34-24`, `ibeam-1__50-50`. A set covers some shapes; anything a set does not draw falls back to the macOS set.

**For Cue:**
- Keep the same model: a set is a folder of vector shapes with the hotspot in the name, and missing shapes fall back.
- Draw our own sets:
  - a refined arrow, in light and dark
  - a bold arrow
  - a soft rounded arrow
  - a touch dot
  - a "Cue" brand pointer
- The macOS set should come from the **running system's own cursors** at record time (`NSCursor` images), which Cue already reads ("the recording's own pointer image"). That needs no bundled art.

## Other bundled assets (not for reuse)

- 148 device-frame PNGs: iPhone 11 to 15, iPad models, MacBook, iMac, Studio Display, Pro Display XDR. Cue draws its device frames in code.
- 18 background-music MP3s in 4 genres.
- Speech-enhancement models (MossFormer2, Restormer) and a Whisper binary.

## Changes for Cue Studio

| Area | Change |
|---|---|
| Title bar | 34 → about 52 tall; Export 28 → 32 high |
| Settings card | width 300 → 340; inner padding 14 → 20 |
| Pills and buttons | height 32 (pills done), full-width buttons 34 |
| Slider rows | ~12 between label and track; ~28 between sliders |
| Section spacing | air instead of hairlines (keep hairlines only between major groups) |
| Timeline | tracks 42 → 48 with 12 gaps; clip and zoom chips get a top-lit vertical gradient and a two-line label |
| Wallpaper grid | 8 per row, square thumbnails |
| Colours | already close; ground `0x0B` → `0x08`, panel `0x17` → `0x13` |
