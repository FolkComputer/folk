# Drawing to the table, and drawing outside a page

Status: proposal, November 2026. Nothing here is implemented yet.

This document answers two questions:

1. Why is it so much code today to draw "to the table", to draw outside
   a program's own quad, or to draw something relative to *two*
   programs (a line between two centroids with a distance label)?
2. What API shape would make those cases one or two lines?

It builds on the open issues
[#273 Table-size quad](https://github.com/FolkComputer/folk/issues/273)
and
[#276 Coordinate conversion proposal](https://github.com/FolkComputer/folk/issues/276),
and on the "surfaces" work merged in #277.

---

## Part 1: How drawing works today

### The pipeline, bottom to top

Every drawn thing ends up as `Wish the GPU draws pipeline NAME onto
canvas ID with arguments/instances ... layer L`. Above that there are
three layers of vocabulary:

| Layer | Example | Keyed on | Units |
|---|---|---|---|
| Raw GPU | `Wish the GPU draws pipeline "line" onto canvas $id ...` | a canvas id + a `surfaceToClip` matrix you supply | whatever the matrix says |
| Primitives (`draw/*.folk`) | `Wish to draw a line onto $p with points ... width ... color ...` | `/p/ has canvas /id/` **and** `/p/ has canvas projection /m/` | the canvas's native units |
| Sugar (`draw/shapes.folk`, `decorations/*.folk`) | `Wish $p draws a circle ...`, `Wish $p is outlined red`, `Wish $p is labelled "hi"` | `/p/ has resolved geometry /geom/` | meters, with `2cm`/`50%` parsing in `shapes.folk` only |

So a thing `$p` is drawable iff somebody claims three statements about
it: `$p has canvas ID with ...`, `$p has canvas projection M`, and
(for the sugar) `$p has resolved geometry {width W height H ...}`.

### Who gets those three claims

**Printed programs (tags).** `tags-geometry.folk:26-70` resolves the
tag's geometry into meters, claims `canvas projection` mapping
page-meters (origin top-left) to clip space, and wishes a 1024x1024
canvas. `tags-to-quads.folk:518-526` claims the page quad in 3D
camera space. `tags-to-quads.folk:529-556` then composites: for
*anything* that `has canvas` and `has quad`, it converts the quad to
`"display $disp"` space with the quad changer, projects the four
corners through the display intrinsics, and draws the canvas texture
as that screen quad. Note this compositor is fully generic. It does
not care that the thing is a tag. The editor already exploits this:
`editor/editor.folk:28-31` claims a synthetic `$editor` with a
borrowed geometry and quad and wishes `$editor has a canvas with layer
98`, and it just works.

**The bare display.** `gpu/canvases.folk:522-556` wraps each display
in a canvas named `[list $disp canvas]` and claims a projection in
**screen pixels**, with the comment "HACK: for now, we just impose a
surfaceToClip that means you draw onto the display canvas in
screen-space pixels (not meters, yet -- what would that mean without
awareness of a specific table/plane?)". That comment is the crux of
this proposal.

**Nothing else.** There is no `table`, no plane, no "the space under
the projector". The commit `61d34d8 Get the table a quad` added a
`builtin-programs/table.folk` that unprojected the four display
corners onto the calibration board's first pose plane and claimed
`table has quad ...`; it was reverted the next day in `5961f8d`
("should be a separate PR") and never came back.

### The three ways to draw outside your own quad today

**Way 1: draw onto `$disp` in pixels, doing the 3D yourself.** This is
what every builtin does. `decorations/title.folk:14-105` (titles,
footnotes, margins) and `geometric/points-at.folk:13-124` (the
"points up at" whisker) both:

1. join on `the quad library`, `the pose library`, `the quad changer`,
   `display /disp/ has width ... height ...`, and `display /disp/ has
   intrinsics ...` (five extra clauses),
2. `fn quadChange` to rehydrate the changer,
3. `quadChange $q "display $disp"` to get the quad into projector
   space,
4. do vector math on the 3D vertices with `::math::linearalgebra`,
5. `$poseLib project $intrinsics $w $h $v` each point down to pixels,
6. recompute the on-screen rotation angle from two projected points
   so text is upright relative to the page,
7. draw onto `$disp` with **pixel** widths and **pixel** text scales
   (`width 4`, `scale 36`) instead of the meters used everywhere else,
8. wrap it in `When -atomicallyWithKey` so it does not flicker.

`points-at.folk:71-75` says it outright: "HACK: This implementation is
sort of inelegant in that it happens entirely in screen-space, because
we need to draw right to the screen right now, and we don't have a
surface-to-clip for that."

**Way 2: project a point from one page onto another page (#277).**
`points.folk:52-82` lets you write `When point $pt corresponds to
point /q/ on $other` and get `$pt` (a `{surface-point $this {x y}}`)
re-expressed in `$other`'s page coordinates, by going through 3D. It
is the right primitive, but it only targets things that `has quad`,
and the table does not. It also goes through a "fake quad with three
zero vertices" to reuse `quadChange`, which only changes quads.

**Way 3: lie about your geometry.** Claim a bigger `resolved geometry`
and a bigger quad for yourself (what `editor.folk` and
`print-editor.folk:49` do) so the canvas covers more table. Works, but
it changes what `$this` *is* for every other program (neighbors,
pointing, camera slices).

### Worked example: a line between two programs with the distance in mm

Here is the shortest version I can write with today's APIs, modelled
on `title.folk`. Assume `$other` is a tag id.

```tcl
When the quad library is /quadLib/ &\
     the pose library is /poseLib/ &\
     the quad changer is /quadChange/ &\
     display /disp/ has width /dw/ height /dh/ &\
     display /disp/ has intrinsics /intr/ {
    fn quadChange
    package require linalg
    namespace import ::math::linearalgebra::norm ::math::linearalgebra::sub

    When -atomicallyWithKey [list $this ruler] \
         $this has quad /q1/ & $other has quad /q2/ {
        set c1 [$quadLib centroid [quadChange $q1 "display $disp"]]
        set c2 [$quadLib centroid [quadChange $q2 "display $disp"]]
        set mm [expr {[norm [sub $c2 $c1]] * 1000.0}]

        set p1 [$poseLib project $intr $dw $dh $c1]
        set p2 [$poseLib project $intr $dw $dh $c2]
        set mid [vec2 scale [vec2 add $p1 $p2] 0.5]
        lassign [vec2 sub $p2 $p1] dx dy
        set radians [expr {-atan2($dy, $dx)}]

        Wish to draw a line onto $disp with points [list $p1 $p2] \
            width 4 color white
        Wish to draw text onto $disp with position $mid \
            text [format "%.0f mm" $mm] scale 30 radians $radians \
            anchor bottom
    }
}
```

That is 25 lines, two libraries, one `fn` rehydration, a change of
3D space, a camera projection, pixel units, and an atomicity key, to
express "line from me to them, labelled with the distance". Everything
except the last two `Wish`es is plumbing that `title.folk` and
`points-at.folk` have each copy-pasted.

### Smaller findings along the way

- `connections.folk` is dead code. It joins on `/source/ has region`
  (nothing claims `has region` any more), calls `dict_getdef` (not
  defined anywhere), and wishes `to draw a stroke` (no handler). The
  same is true of `geometric/intersect.folk` (`has region`,
  `regionToBbox`) and the commented-out region code in
  `terminal.folk`. These are the Folk1 "region" API; PR #258 (unmerged)
  noted them as cruft. `group.folk` starts with `return`.
- Units are inconsistent by canvas. On a page canvas, line `width` and
  text `scale` are meters (`0.01`); on the display canvas they are
  pixels (`4`, `36`). `draw/shapes.folk` accepts `2cm`/`50%` via
  `drawRelativePhysicalLength`, but `draw/line.folk`, `draw/text.folk`,
  `draw/circle.folk` take raw floats.
- `demos.folk` tag 45005 wishes `draws a circle offset [list expr
  {sin($t) * 50} 0]`, which is the literal list `expr {...} 0`; it
  does not animate.
- Page canvases are fixed 1024x1024 regardless of physical size
  (`tags-geometry.folk:64` TODO), which matters for a table-sized
  canvas (see below).

---

## Part 2: Proposal

The one-sentence version: **make the table a surface like any other,
then give people vocabulary for points that live on other surfaces.**
Almost all of the machinery exists; what is missing is three claims
about `table` and some nouns.

### 2.1 `table` is just another drawable thing (small PR, big payoff)

Add `builtin-programs/table.folk` that, for each calibrated display,
claims the same three statements every page gets:

```tcl
Claim table has quad $tableQuad                ;# in "display $disp" space
Claim table has resolved geometry [dict create width $w height $h]
Claim table has canvas projection $proj        ;# meters from top-left, like pages
Wish table has a canvas with width $cw height $ch layer -1
```

Because the compositor in `tags-to-quads.folk:529` and the `has a
canvas` handler in `gpu/canvases.folk:473` are already generic, these
four lines make **all** of this work with zero changes to `draw/*`:

```tcl
Wish to draw a line onto table with points {{0.10 0.10} {0.60 0.40}} width 0.004 color red
Wish table draws a circle with center {0.5 0.3} radius 4cm color cyan
Wish table draws text "hello" with position {0.2 0.2} scale 2cm
Wish table is outlined green
Wish table displays image "foo.png" with position {0 0} width 0.3
When point [$pointsLib point 0 0] corresponds to point /p/ on table { ... }   ;# #277 for free
```

Coordinates are **meters on the table**, origin at the top-left of the
projector's footprint, x to the right and y down as seen by the
projector. This is the "draw in table space, rectilinear to the table,
in real-world units" that #273 asks for, and it is the answer to the
"what would meters mean without a table/plane?" comment in
`canvases.folk`.

**Where the plane comes from.** Three sources, in priority order:

1. A saved table plane: `Hold! -save ... Claim the table plane for
   display $disp is {origin {...} normal {...}}`. Captured by a
   one-off wish, e.g. `Wish the table plane is captured from $this`
   while a program lies flat on the table (its page quad *is* a
   plane sample). A web button on `/calibrate` can do the same with
   the calibration board.
2. Fallback: fit a plane to all currently visible page quads
   (least-squares on vertices). Most pages are on the table, so this
   is usually right and needs no user action. Re-fit only when
   nothing is saved.
3. Last resort: the plane at depth 1.5m facing the projector, which is
   what `web/new.folk:180` already assumes for virtual programs.

Given a plane, the table quad is the display's four corners
unprojected onto it, exactly as `61d34d8` did (that commit's
`$poseLib unproject` and `undistort` should come back with it). The
table's x axis should be the projector's x axis projected into the
plane, so "up on the table" matches "up on the screen", which is what
`web/new.folk` virtual programs and the display-saver assume.

**Canvas size.** One 1024x1024 canvas across a 1.5m table is under
1 px/mm; text would be mush. Size the table canvas to the display
resolution (each display gets its own table). This also fixes the
blurry-pages TODO if the same "pixels per meter" rule is applied to
page canvases later.

**Layering.** Table at layer -1 so pages draw over it; the display
canvas stays at 99/100 for the calibration warning and titles. Once
titles move to the table (below), nothing user-facing needs the pixel
display canvas, and it can become an internal detail.

**Multiple displays.** `table` is the table of the only display in
the common case. With several displays, claim `[list table $disp] has
quad ...` for each and alias `table` to the first; a program that
cares can name the display.

**What to migrate once this exists.** `title.folk`, `points-at.folk`,
`mask-tags.folk`, `display-saver.folk`, the calibration warning in
`load-calibration.folk`, and PR #282's video window all draw onto
`$disp` in pixels with hand-rolled 3D. Each becomes a `Wish ... onto
table` in meters, and drops the five-clause library join.

### 2.2 Points that know where they live

With the table drawable, the remaining pain is expressing *where*
things are. Today the only tools are 3D quad vertices and the
`surface-point` from #277. Proposed vocabulary, all built on the
existing quad changer, `quadLib pointToXY`/`xyToPoint`, and
`projectAlongSourceNormal`:

**Reactive position claims.** A rule family that turns a quad into
named 2D features on any surface:

```
When $other has center /c/ on table { ... }
When $other has corner topleft /tl/ on table { ... }
When $other has edge top /from/ /to/ on table { ... }
When $other has center /c/ on $this { ... }          ;# page-relative, as in #277
```

Implemented with the "wish when someone Whens" idiom already used for
`has neighbor`, `points up at`, and `corresponds to point`: a `When
when /a/ has center /c/ on /surface/ ...` auto-wishes the conversion,
and a single handler joins `$a has quad` with `$surface has quad`,
changes spaces, projects along the target normal, and claims the
answer in the target's meters. This is ~40 lines, almost all of them
already in `points.folk:52-82`.

**Derived measurements.** The same handler can claim the thing people
actually want to label:

```
When the distance from $this to $other is /m/ { Wish $this is labelled "[expr {$m*1000}] mm" }
When the direction from $this to $other on table is /radians/ { ... }
```

Distance is measured in 3D (centroid to centroid in `"display $disp"`
space), so it is correct even for a page held off the table.

With 2.1 and 2.2 together, the worked example becomes:

```tcl
When $this has center /a/ on table & $other has center /b/ on table &\
     the distance from $this to $other is /m/ &\
     the direction from $this to $other on table is /radians/ {
    Wish to draw a line onto table with points [list $a $b] width 4mm color white
    Wish table draws text [format "%.0f mm" [expr {$m*1000}]] \
        with position [vec2 midpoint $a $b] scale 2cm radians $radians
}
```

Five lines, no libraries, no `fn`, no intrinsics, no pixels. (The
`-atomically` concern goes away too: both centers derive from the same
`has quad` claims, so they update in the same frame; if that proves
false in practice, `When -atomically` still works here.)

**Points as values (optional, later).** #276's direction of tagging
points with a home surface (`{surface-point 176 {0.05 0.01}}`) and
converting at the point of use, which osnr floated in the thread. The
draw handlers would call one shared `drawResolvePoints $target
$points` that leaves bare `{x y}` alone and converts tagged points to
`$target`'s frame. It is more magical and needs a synchronous quad
lookup inside the handler, so I would ship the reactive form first and
add this only if people keep writing `has center ... on table` joins
for a dozen points at once.

### 2.3 Sugar on top (cheap once 2.1 and 2.2 exist)

These are the one-liners people reach for first, each ~10 lines over
the above:

```
Wish $this is connected to $other                          ;# revive connections.folk on the table
Wish $this is connected to $other with label distance       ;# the mm readout
Wish $this draws a circle above with radius 3cm             ;# "above" = off the top edge, onto table
Wish $this draws text "hi" to the right                     ;# what title.folk does, in table space
Wish the table is outlined                                  ;# debug the plane
Wish the table shows a grid every 10cm                      ;# debug/calibration aid
```

`Wish $this draws a circle offset {up 50%}` already exists in
`shapes.folk`; today it clips at the page edge because it draws onto
the page canvas. With a `side`/`above`/`beside` option (or when the
offset leaves the page), `shapes.folk` can route the same request
through `$this has corner ... on table` and draw onto `table` instead.
That answers #165 ("what should `draws circle above $this` do under 3D
calibration?"): it lands on the table plane next to the page.

### 2.4 Things to decide, and my recommendation

- **Per-page overflow canvas instead of the table?** An alternative to
  2.1 for "draw just outside my page" is `Wish $this has a drawing
  margin 5cm`, which composites a buffered quad and shifts the
  projection so negative coordinates are visible. It keeps page
  coordinates, which is nice, but it does not solve lines *between*
  pages, costs canvas resolution, and makes "where is my page" differ
  per consumer. Recommendation: build the table first; add margins
  only if the table turns out insufficient for the "label beside me"
  case.
- **Units.** Accept `4mm`, `2cm`, `0.5m` (and `%` where it makes sense)
  in `draw/line.folk`, `draw/text.folk`, `draw/circle.folk`, not just
  `shapes.folk`, using the existing `drawPhysicalLength` in
  `lib/math.tcl`. Keep bare floats as meters. This matters more once
  people draw on a 1.5m surface where `0.004` is unreadable.
- **The name `table`.** A bare word in a statement is slightly magic
  but reads well and matches `the clock time is`, `the quad library
  is`. If a tag-pair-defined region (#273's suggestion) is wanted
  later, it can claim its own quad as `[list table-region $name]` and
  everything in 2.2 works on it unchanged.
- **Plane capture UX.** Start with the automatic fit (source 2) so
  nothing is required of users; add the explicit capture when the fit
  misbehaves in practice (tall objects, pages in hand).

### 2.5 Suggested order of PRs

1. `table.folk`: plane (fit + saved + fallback), `table has quad`,
   `resolved geometry`, `canvas projection`, canvas sized to the
   display. Restore `unproject`/`undistort` from `61d34d8`. Delete the
   dead `connections.folk`/`intersect.folk` region code in the same
   pass or a sibling PR.
2. Position claims (`has center/corner/edge ... on`, `the distance
   from ... to ... is`), refactoring `points.folk` to share the
   conversion.
3. Migrate `title.folk`, `points-at.folk`, `mask-tags.folk`,
   `display-saver.folk` onto the table; delete their copies of the
   project-to-pixels dance.
4. Physical units in all `draw/*` primitives.
5. Sugar: `is connected to`, `draws ... above/beside`, table grid.
