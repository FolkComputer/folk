# Metal metaball playground — △ ○ ▩ ▦ ✖︎

A macOS Metal playground: a colorful metaball field you steer with a PS5
DualSense (or any extended gamepad). The five glyphs **△ ○ ▩ ▦ ✖︎** sit
along the bottom of the screen; pressing the matching button lights its
glyph up and bursts a metaball in that button's color out of it.

## Running it

Two ways, same file:

- **Xcode:** open `MetaballPlayground.playground` and run it. The scene
  appears in the live view (show the assistant editor / live view if it's
  hidden).
- **Terminal:** `swift MetaballPlayground.playground/Contents.swift` —
  opens a resizable window.

Plug in (or pair) the DualSense before or after launch; the dot in the
top-left corner turns green when a controller is connected. Without a
controller the ambient metaballs just drift on their own.

## Controls

| Input | Effect |
|---|---|
| Left stick | Move the big warm metaball |
| Right stick | Move the teal buddy metaball |
| R2 / L2 | Inflate / deflate the big metaball |
| △ (triangle) | Light **△**, green burst |
| ○ (circle) | Light **○**, red burst |
| ▩ (square) | Light **▩**, pink burst |
| ▦ (touchpad click) | Light **▦**, silver burst (Options button on non-DualSense pads) |
| ✖︎ (cross) | Light **✖︎**, blue burst |

## How it works

Everything lives in one `Contents.swift`:

- The Metal shader is compiled at runtime from a source string (so no
  `.metal` build step — playground-friendly). A full-screen triangle's
  fragment shader evaluates the classic metaball field
  `Σ rᵢ² / dᵢ²`, thresholds it with smoothsteps for the body/rim, and
  color-mixes each pixel by the balls' field contributions.
- The five glyphs are the literal Unicode characters, rasterized once via
  AppKit into a small texture atlas and composited by the same fragment
  shader, tinted PlayStation-style (green/red/pink/silver/blue) and
  brightened by a per-button glow uniform that decays after release.
- Input is polled per frame from the GameController framework.
  `GCExtendedGamepad`'s A/B/X/Y map to cross/circle/square/triangle on
  the DualSense; the touchpad click comes from `GCDualSenseGamepad`.
  Button rising edges spawn short-lived "burst" balls that rise out of
  the pressed glyph and fade into the field.
