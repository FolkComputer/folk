# Film Strip Kit

By default Folk only "thinks" about images as 2 things:

- pixels (PNG, JPG, GIF)
- slices (2D sub-quad slices of image memory from the camera feed)

The Film Strip Kit extends this with **named frame slices**: named
sub-rectangles of an image that can be addressed individually or
played back as an animated sequence — table-shot capture grids,
film-strip animation, kaleidoscopes.

## Vocabulary

| Statement | Meaning |
| --- | --- |
| `Claim $this has named frame slices { cat 0% 0% 50% 50%  dog 50% 50% 100% 0% }` | Define named frames on this object. |
| `Claim $this has frame source image "strip.png"` | Optional: slice this still image instead of the live camera slice. |
| `Wish $this displays named frame slices as a sequence with fps 30` | Animate through the frames in spec order. |
| `Wish $this displays named frame slices as a sequence` | Same, at the default 10 fps. |
| `Wish $this displays named frame slice cat` | Display one frame, statically. |
| `When $this has named frame slice cat /im/ { ... }` | React to one frame as an `Image`. |
| `When $this has named frame slice images /images/ { ... }` | React to all frames: an ordered dict of name → `Image`. |

## Frame spec format

The spec is groups of 5 words: `name x1% y1% x2% y2%`.

- The four coordinates are **two opposite corners, in any order**, as
  percentages of the source image's width and height. So
  `dog 50% 50% 100% 0%` is the top-right quadrant.
- Percentages outside 0–100 are clamped; a frame may not have zero
  width or height.
- Names must be unique, and the name `images` is reserved.
- Frame order in the spec is the animation order.

A malformed spec surfaces as a normal on-table program error (red
outline) on the object — once something consumes the slices.

## Source resolution

If the object claims a `frame source image`, that image is sliced
(claim at most one; GIF sources use frame 0 only — slicing every
frame of an animated GIF is future work). Otherwise the object's live
**camera slice** is sliced, re-cut on every camera frame — this is
what makes table shots work. Claiming a still source while the camera
branch is live reactively switches the source over.

Slicing is lazy either way: nothing is cut (and for camera sources,
no camera slice is demanded) until some `When` actually watches the
frames.

## fps semantics

`fps` is clamped to 0–120; `fps 0` freezes on the first frame; the
default (when omitted) is 10. The sequence bottoms out in ordinary
`Wish $p displays image ...`, so geometry fitting and GPU texture
reuse behave like any other image display.

## Lifetime caveat

Frames are **zero-copy views** into the source image. For camera
sources that means a frame `Image` is only valid inside the reactive
match that handed it to you — never stash one in a variable that
outlives your `When` body's match.
