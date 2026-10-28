# 10. Screen Studio motion reference

How Screen Studio 4.0.1 moves things. This was measured from its app bundle on 2026-10-28 and is written here in our own words, as numbers and rules. Cue Studio uses it to match how the result *feels*. No code was copied. Layout and tokens are in [08](08-ui-reference.md) and [09](09-design-tokens.md).

## Spring

Every motion in the app is one spring: one physics step per millisecond.

- **Acceleration:** a = (−stiffness·x − damping·v) / mass.
- **Rest:** the spring stops once both speed and distance are under `max(1, |start − target|) × precision`. Precision is 0.002.
- **Clamp (on by default):** while moving toward the target faster than distance·√(stiffness/mass), damping is raised to critical, 2√(mass·stiffness). So a clamped spring never overshoots, even with bouncy constants.
- **Mass 0** jumps straight to the target.
- **Fit to a time limit:** if a spring needs longer than the time available, stiffness is scaled by r² and damping by r, where r = settle time ÷ time available. With 2 frames or less available, it jumps.
- **Default for a new project:** stiffness 125, damping 12, mass 1.5, clamped.

| Preset | Stiffness | Damping | Mass |
|---|---|---|---|
| Cursor Smooth | 470 | 70 | 3 |
| Cursor Medium | 340 | 60 | 3 |
| Cursor Rapid | 530 | 40 | 1 |
| Zoom Focused | 250 | 40 | 2.25 |
| Zoom Smooth | 170 | 50 | 3 |
| Drag-lock | 1000 | 40 | 1, fitted to 40 ms |
| Quick fade | 600 | 50 | 1 |

Custom spring sliders range:
- stiffness 5–600
- damping 5–200
- mass ("momentum") from 1

## Cursor

**Input thinning.** A mouse sample is kept only if it moved at least 10 px. Clicks are always kept.

**Landing on clicks.** When a click is due within 500 ms, the cursor aims at the click's position, so it arrives exactly on it.

**Which spring, frame by frame:**
- Dragging: the drag-lock spring.
- A click within 175 ms: Rapid.
- Otherwise: the user's chosen spring.

**Press.** The cursor scales to 0.9 while the button is held.

**Hide when idle.** The cursor shows only if the mouse moved in the last N ms (default 2000; range 0.5–5 s). It fades with the Medium spring and gains up to 10 px of blur as it fades.

**Hide while typing.** The cursor hides after 3 or more keys in 1800 ms with no mouse movement since the last key.

**Remove shakes.** A sample is dropped when it is more than T away from *both* of the next two samples, measured as horizontal plus vertical distance. A dropped press takes its release with it. T defaults to 500 (range 100–2000).

**Loop.** Cursor data stops at end − N, and the first position is added again, so the spring glides home. N defaults to 1 s (range 1–4).

**Tilt (default rotation):**
- Horizontal speed is smoothed with a 120 ms time constant.
- Angle = speed (px/ms) × 12 × ratio, capped at ±20°. Ratio defaults to 0.5.
- The first 500 ms are ignored.
- The angle moves through a 120/8/1 spring.

**Shape changes.** The cursor shape may change only around a press, release or drag. It goes back to the arrow when the cursor moves more than 250 ms after a release.

## Zoom

**Automatic zooms:**
1. Each click becomes a range from 300 ms before it to 2500 ms after it.
2. A range never runs later than 800 ms before the end, and clicks in the last 1 s are ignored.
3. Ranges merge while they overlap or are 2500 ms or less apart.
4. Every range gets the default level, **2×**.

**Following the cursor while zoomed:**
- The cursor samples inside a zoom are grouped. A group grows until its bounding box would exceed **half the visible area** at that zoom.
- The camera aims at the group's time-weighted mean position.
- In effect, a half-view dead zone, with jumps between groups taken by the zoom spring.

**Animation:**
- Zoom springs: Focused or Smooth (see the table above).
- "Instant" makes the spring mass 0 for the length of the zoom.
- "Start early" leads the zoom by 350 ms.
- Number keys 1–9 set the level from 1.0× to 2.6×, in steps of 0.2.

## Click effects

| Effect | Behaviour |
|---|---|
| Ripple | Lasts 1 s. Bends the picture rather than drawing on it. Strength e^(−3t)·sin(9.4t). Starting radius 0.04 W, growing 0.2 W per second. Band 0.05 W wide; displacement 0.015 W. |
| Circle | Lasts 450 ms. Grey disc (0.87, alpha 0.6) with a faint dark rim. Radius grows from 0.002 W to 0.03 W, easing out (cubic). Fades in over the first 15%, then out by 90%. |
| Limit | At most 3 clicks on screen, none older than 1 s. |

W is the video's width.

## Motion blur

- Each moving element is smeared back toward where it was one frame earlier.
- Length = setting × (fps ÷ 60) × that movement.
- 16 samples for export, 6 during playback.

## Camera

- **Default size:** 0.33 of the frame.
- **Size during zoom:** 0.8 when turned on.
- **Hide during silence:**
  - Silence is any stretch under 10% of peak level, measured in 50 ms windows, lasting at least 5 s (range 2–15 s).
  - The camera hides from 0.5 s into the silence until 0.5 s before it ends.

## Transcript

- **Pause:** any gap of 1 s or more between words.
- **Tighten:** keeps 100 ms on each side of a pause. It does nothing if 200 ms or less would go.
- **Cutting words:**
  - A cut edge sits 30 ms inside the neighbouring kept words, or at the midpoint when the gap is under 60 ms.
  - Cuts closer together than 60 ms merge.
- **Fillers removed:** um, uh, er, ah, hmm, mhmm, mm, mmm, huh, uh-huh, erm, umm, uhh.
- **Fillers underlined only:** like, you know, so, I mean, kind of, sort of, actually, basically, literally.

## Defaults

| Setting | Default |
|---|---|
| Padding | 0.1 |
| Screen corner radius | 16 |
| Camera corner radius | 0.15 |
| Shadow | intensity 0.3, distance 25, angle 45°, blur 20 |
| Inset | 0 |
| Cursor size | 48 |
