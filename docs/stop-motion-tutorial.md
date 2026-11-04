# Build your own stop-motion animation booklet in Folk

This tutorial walks you from your first one-line Folk program to a
small booklet of paper pages that, together, are a stop-motion
animation tool: a **Stage** page that sees the table through the
camera, a **Snap** button that freezes a frame, a **Play** page that
flips through the frames, and an **Erase** page that starts over.

Along the way you'll learn the four things nearly every Folk program
is made of:

| Construct | What it does |
|-----------|--------------|
| `Claim`   | States a fact, for as long as the page is on the table |
| `Wish`    | Asks for something to happen (a label, a shape, a camera slice) |
| `When`    | Reacts whenever matching facts or wishes exist |
| `Hold!`   | Keeps a fact around *after* the code that made it has moved on |

Everything here uses ordinary Folk idioms you'll find in
`builtin-programs/` and in the
[language reference](../README.md#language-reference).

## What you need

- A working Folk table (camera, projector, printer) that is
  calibrated. See <https://folk.computer/pilot>.
- A laptop or phone on the same network, to open the web editor.
- Four or five sheets of paper (card stock is nicer), scissors, and
  something to animate: a coin, a paper cut-out, a LEGO figure.

## Part 0: a program is a page

In Folk, a program is a physical page. The page carries a printed
AprilTag so the camera can find it. While the camera can see the tag,
the program runs. Cover the tag, fold the page, or pick it up, and the
program stops, and everything it claimed, wished, or drew vanishes
with it.

### Make a page

1. Open the web editor on your Folk machine:
   `http://folk-NAME.local:4273/new` (replace `folk-NAME` with your
   machine's hostname).
2. Type a program into the text box.
3. Press **Save**. A *virtual page* appears on the table where the
   editor box is. Drag the box around to move it.
4. Press **Print**. The printer produces a real page with a tag on it.
   Put it on the table and the same program runs from paper.

Try this first:

```tcl
Wish $this is labelled "Hello, table!"
Wish $this is outlined green
```

Two things to notice.

`$this` is the page the code is printed on. For a printed page it's
the page's tag number (like `1234`); for a virtual page it's a
generated name. You almost never type a page id by hand. You say
`$this` and let each printed copy fill in its own.

Folk programs are Tcl. If you want a comment after some code, write it
with a semicolon: `Wish $this is outlined green ;# the outline`. A
bare `#` after code is not a comment in Tcl and will cause an error.

### What a booklet is

A booklet is just several of these pages, bound or stapled so you can
flip them. Each page is its own program. A page is **out** when its
tag is visible to the camera, and **away** when it's folded under,
covered, or closed. Flipping a booklet is flipping programs on and off.
The animation tool at the end of this tutorial is a four-page booklet.

## Part 1: Claim

A `Claim` states a fact in Folk's shared database. Make a page that
says:

```tcl
Claim $this is a sun
```

Nothing visible happens yet. But while this page is out, the database
contains the statement:

```
<page> claims <page> is a sun
```

The moment the page goes away, the claim is retracted automatically.
You never un-claim anything by hand.

Two habits worth forming now:

- **Scope claims to the page.** Say `$this is a sun`, not `there is a
  sun`. When you print the page twice (or have the virtual and the
  printed copy out at once), each copy claims about itself and they
  don't collide.
- **Claims are plain words.** `Claim $this has 5 petals` is just as
  valid as `Claim $this is a sun`. There is no schema. Pick phrasing
  that reads like a sentence, because you'll be writing `When`
  patterns that match it later.

## Part 2: Wish

A `Wish` is a request. The page that wishes doesn't do the work;
some other program that is watching for that wish does. The builtin
programs under `builtin-programs/draw/` and
`builtin-programs/decorations/` fulfil the common ones.

Put these on your Sun page under the claim:

```tcl
Claim $this is a sun

Wish $this is labelled "Sunny"
Wish $this is outlined yellow
Wish $this draws a circle with color yellow filled true
Wish $this draws text "noon" with offset {down 30%} color orange
```

You should see a yellow outline, a filled circle in the middle of the
page, the word *Sunny* and, below centre, *noon*.

Things you can wish for on a page (all fulfilled by builtins):

| Wish | Effect |
|------|--------|
| `Wish $this is labelled "text"` | Text in the page's body area |
| `Wish $this is titled "text"` | Text just above the page |
| `Wish $this is outlined red` | A border around the page |
| `Wish $this draws a circle with color red radius 20%` | A circle (also `square`, `triangle`, `hexagon`, `rect`) |
| `Wish $this draws text "hi" with offset {right 25%}` | Positioned text |
| `Wish $this draws a polyline {{0 0} {right 40%}} with color white` | Lines |
| `Wish $this displays image "photo.png"` | An image from `~/folk-images/` |
| `Wish $this displays camera slice $slice` | A camera slice (Part 5) |

Lengths such as `radius`, `thickness` and offsets accept a percentage
of the page (`20%`) or a length with a unit (`3cm`, `20mm`, `0.1m`).
Colour names are the CSS names (`red`, `orange`, `deeppink`, and so
on).

Like claims, wishes vanish with the page. A wish is a fact of the form
`<page> wishes ...`, so other programs can react to *wishes* with
`When` just as they react to claims. That's how `is labelled` works:
`builtin-programs/decorations/label.folk` has a `When` that watches
for `/someone/ wishes /thing/ is labelled /text/` and draws the text.

## Part 3: When

`When` is where programs become reactive. Make a second page, the
Flower:

```tcl
Claim $this is a flower

When /thing/ is a sun {
    Wish $this is labelled "$thing is shining on me"
    Wish $this draws a circle with color pink radius 20%
    Wish $thing is outlined orange
}
```

Put both pages out. The Flower labels itself with the Sun's id, draws
a pink circle, and outlines the Sun in orange. Take the Sun away and
all three disappear. Bring it back and they return. You didn't write
any of that lifecycle code: whatever a `When` body claims, wishes, or
draws lives exactly as long as the match that produced it.

The rules of a `When` pattern:

- `/thing/` is a **variable**. It matches any single word and binds it,
  so `$thing` is available inside the body.
- `/someone/`, `/something/`, `/anyone/`, `/anything/` match without
  binding, when you don't care about the value.
- `/nobody/` and `/nothing/` **negate** the pattern. The body runs only
  while *no* statement matches.
- `&` **joins** patterns. A variable used in two arms must be the same
  value in both.
- `$var` inside a pattern substitutes a value you already have.
- Both `Claim`ed facts and `Wish`es are matchable. Writing
  `When /x/ is a sun` matches `... claims /x/ is a sun`; to match a
  wish, write it out: `When /someone/ wishes /x/ is outlined /c/`.
- A `When` can contain another `When`. The inner one is created once
  per outer match and is torn down with it.

Some more pages for the garden.

**Night watch**, using negation:

```tcl
When /nobody/ is a sun {
    Wish $this is labelled "It's night. Bring out a sun."
    Wish $this is outlined blue
}
```

**Weather report**, using the collected-results form, which hands you
*all* matches at once as a list of dictionaries:

```tcl
When the collected results for [list /s/ is a sun] are /suns/ {
    Wish $this is labelled "[llength $suns] sun(s) in the sky"
}
```

**Wand**, using the builtin `points up at` geometry (the top edge of
the page points at another page):

```tcl
Wish $this is outlined white

When $this points up at /target/ {
    Wish $target is outlined red
    Wish $this is labelled "pointing at $target"
}
```

**Petal count**, using a join. Add `Claim $this has 5 petals` to the
Flower, then:

```tcl
When /f/ is a flower & /f/ has /n/ petals {
    Wish $this is labelled "$f has $n petals"
}
```

When you break a `When` pattern over several lines, end each line with
a backslash, as in the builtins:

```tcl
When /f/ is a flower &\
     /f/ has /n/ petals {
    Wish $this is labelled "$f has $n petals"
}
```

## Part 4: a first booklet, shapes and text that appear when pages are out

Print the Sun, Flower, Night watch, Weather report and Wand pages and
staple them into a booklet. Now play with it:

- Open to the Flower alone. It's blank. Open the Sun too. The pink
  circle and label appear on the Flower.
- Open Night watch. Its message shows only while the Sun page is
  closed.
- Print the Sun twice and watch Weather report count to two.
- Point the Wand's top edge at any page.

What you're seeing is the whole model of Folk. Pages don't send
messages to one another. Each page just states what's true about
itself and reacts to what's true on the table. Which pages are open
decides which facts exist, and the `When`s do the rest.

Everything from here on is the same model, pointed at the camera.

## Part 5: a camera slice

A **camera slice** is the camera's view of one page, cut out and
straightened into a flat image. Folk knows where each page's four
corners are (its *quad*), so it can warp that part of the camera frame
into a rectangle the same shape as the page.

Make a new page, the Stage:

```tcl
Claim $this is a stage

When $this has camera slice /slice/ {
    Wish $this displays camera slice $slice
}
```

Put it on the table and wave your hand over it. The projector draws,
on the page, what the camera sees of the page. Anything you place on
the Stage shows up in the slice, as long as you don't cover the tag.

How this works, because you'll rely on it in a moment:

- `builtin-programs/camera/slice.folk` has a `When` waiting for
  `/someone/ wishes /p/ has camera slice`. It also has a rule that
  turns *your* `When $this has camera slice /slice/` into exactly that
  wish on your behalf, so you don't have to wish for the slice
  separately. If nobody is asking for a page's slice, no slice is
  computed.
- For every camera frame it claims `$p has camera slice $slice` where
  `$slice` is a fresh image, and retracts the previous one. So your
  `When` body re-runs for each frame, and the image you were handed is
  **freed** as soon as the next frame arrives.
- You can ask for a particular resolution instead of the camera's
  natural one:

```tcl
When $this has camera slice /slice/ with width 640 {
    Wish $this displays camera slice $slice
}
```

Optional: a bigger stage. Printed pages can ask for a larger quad
than the paper itself. Adding

```tcl
Claim program $this is scaled by x 2 y 2
```

makes the page's region twice as wide and tall, extending right and
down from the tag, so the slice covers a bigger patch of table for
your set. (It only applies to printed pages, not virtual ones.)

## Part 6: Hold! freezes a frame

A `Claim` lives only as long as the code that made it. The camera
slice is replaced dozens of times a second. For stop motion we need
the opposite: keep *this* frame after the camera has moved on. That's
what `Hold!` is for.

`Hold!` makes a statement that stays in the database until another
`Hold!` **with the same key** replaces it. Keys are scoped to the
page (`$this`) so two pages can't clobber each other. Holding an
empty statement, `Hold! -key something {}`, clears that key.

```tcl
Hold! -key score Claim $this has score 0

When $this has score /n/ {
    Wish $this is labelled "score: $n"
}
```

A held statement outlives the `When` body, the camera frame, and
even the page being picked up and put back down. It's how you give a
page memory.

### The Snap button

Make a small page:

```tcl
Claim $this is a shutter
Wish $this is labelled "SNAP"
Wish $this is outlined red
```

Nothing else. Its whole job is to exist. The Stage will react to it.
If you want it to feel like a button, fold it following
<https://folk.computer/guides/button>, so the tag is only visible while
you press.

### Teach the Stage to snap

Replace the Stage program with this:

```tcl
Claim $this is a stage

When $this has camera slice /slice/ {
    Wish $this displays camera slice $slice
}

if {[llength [Query! $this has frame count /n/]] == 0} {
    Hold! -key count Claim $this has frame count 0
}

When the image library is /imageLib/ &\
     /shutter/ is a shutter {
    ForEach! $this has camera slice /slice/ &\
             $this has frame count /n/ {
        set width [$imageLib Image_width $slice]
        set height [$imageLib Image_height $slice]
        set frame [$imageLib copyCrop $slice 0 0 $width $height]
        Hold! -key [list frame $n] \
            -destructor [list $imageLib imageFree $frame] \
            Claim $this has frame $n image $frame
        Hold! -key count Claim $this has frame count [expr {$n + 1}]
    }
}

When $this has frame count /n/ {
    Wish $this is labelled "$n frames"
}
```

Put the Stage out, place your figure on it, and show the Snap page to
the camera. The label ticks to *1 frames*. Move the figure, snap
again: *2 frames*.

Walk through the new parts:

**The frame counter.** `Query!` is a one-off, non-reactive lookup. If
the page has no counter yet, we hold one at zero. We don't hold
unconditionally, because the page's code re-runs every time the page
is re-detected and we don't want that to wipe the count.

**The image library.** Images are handled by a builtin C library.
`When the image library is /imageLib/` binds it so we can call
`copyCrop`, `Image_width` and `imageFree` on it.

**`ForEach!` instead of a nested `When`.** You might expect

```tcl
When /shutter/ is a shutter & $this has camera slice /slice/ { ... }
```

but that body would re-run on *every camera frame* while the shutter
is visible, snapping a burst of frames. `ForEach!` is the sampling
cousin of `When`: it runs the body once over whatever matches *right
now* and does not subscribe. So the capture happens once each time
the shutter page appears.

**Copying the slice.** The slice image is freed when the next camera
frame arrives, so we copy it with `copyCrop` (a crop the size of the
whole image is a copy). The `-destructor` on the `Hold!` frees our
copy when the held statement is eventually replaced or cleared, so
you can snap all day without leaking memory.

**One key per frame.** Each frame is held under its own key,
`[list frame $n]`, so holding frame 3 doesn't replace frame 2. The
counter is held under `count`. Scoping keys to the page is automatic:
the real key is `$this` plus what you pass.

## Part 7: a sequence of camera slices

You already have a sequence. Every snap adds a statement:

```
<stage> claims <stage> has frame 0 image <image>
<stage> claims <stage> has frame 1 image <image>
...
```

Let's make it visible and make it erasable.

### Show the last frame on the Stage

Add to the Stage program:

```tcl
When $this has frame count /n/ {
    set last [expr {$n - 1}]
    When $this has frame $last image /im/ {
        Wish $this displays image $im with position {0 0} width 0.05
    }
}
```

The most recent frame appears as a small thumbnail in the page's
top-left corner (`position` and `width` for `displays image` are in
metres, so `0.05` is five centimetres wide). That's a poor animator's
onion skin: line your figure up against it before the next snap.

Note the `$last` inside the inner pattern. `When` substitutes `$`
variables you already have, so this inner `When` only matches the
latest frame.

### The Erase page

```tcl
Claim $this is a film eraser
Wish $this is labelled "ERASE"
Wish $this is outlined white
```

And in the Stage:

```tcl
When /eraser/ is a film eraser {
    ForEach! $this has frame /n/ image /im/ {
        Hold! -key [list frame $n] {}
    }
    Hold! -key count Claim $this has frame count 0
}
```

Clearing a key with `{}` retracts that frame's statement, which runs
its destructor and frees the image. Then the counter goes back to
zero. Hide the Erase page again after using it, or the next
re-detection of the Stage will erase again.

## Part 8: the Play page

The Play page turns the sequence back into motion. It needs time, and
Folk provides a clock as a statement, `the clock time is /t/`, that is
re-claimed many times a second.

```tcl
When /stage/ is a stage {
    When the collected results for [list $stage has frame /n/ image /im/] are /frames/ &\
         the clock time is /t/ {
        if {[llength $frames] == 0} {
            Wish $this is labelled "No frames yet"
            return
        }
        set ordered [lsort -integer -index 0 \
            [lmap f $frames {list [dict get $f n] [dict get $f im]}]]
        set fps 6
        set i [expr {int($t * $fps) % [llength $ordered]}]
        Wish $this displays image [lindex $ordered $i 1]
        Wish $this is labelled "frame $i of [llength $ordered]"
    }
}
```

Reading it from the outside in:

1. `When /stage/ is a stage` finds the Stage, whatever its id is. The
   Play page never needs to know the Stage's number, so you can print
   either page again and they still find each other.
2. The collected-results clause gathers every held frame into a list
   of dicts like `{n 2 im <image>}`. It's inside the outer `When` so
   we can write `$stage` into the pattern.
3. `& the clock time is /t/` re-runs the body on each tick.
4. We sort frames by number, pick one by time, and wish to display
   it. The wish from the previous tick is retracted automatically, so
   only one frame shows at a time.

Change `set fps 6` to taste. Or make speed a page of its own: a
`Claim $this wants 12 frames per second` page and a
`When /someone/ wants /fps/ frames per second` in the Play program.
That's left as an exercise.

## Part 9: assemble the booklet and shoot

Print four pages and bind them:

1. **Stage**: the full program from Parts 6 and 7.
2. **Snap**: `Claim $this is a shutter`.
3. **Erase**: `Claim $this is a film eraser`.
4. **Play**: the program from Part 8.

Shooting a film:

1. Open the booklet to the Stage, flat on the table, tag uncovered.
   Put your figure on it.
2. Hold the Snap page (or press the Snap button) in view of the camera
   for a moment. Watch the count go up and the thumbnail update.
3. Move the figure a little. Snap again. Repeat.
4. Open the Play page. Your film loops on it.
5. Open Erase when you want to start over, then put it away.

Tips:

- Keep the Stage's tag visible. If the tag is lost, the page's code
  reruns on re-detection; your held frames survive, but a Snap or
  Erase page that's still out will fire again.
- If the slice jitters, add `Wish tag $this is stabilized` to the
  Stage.
- Lighting changes between frames are the enemy of stop motion.
  Block out the projector's own image from the Stage by not drawing on
  it while shooting, or keep the preview and thumbnail small.
- To save frames to disk, bind `the jpeg library is /jpegLib/` and
  call `$jpegLib saveAsJpeg $im /path/to/file.jpg` inside a
  `ForEach!` over the frames.

## Why this is the idiomatic shape

Look at the roles once more:

- The Snap and Erase pages contain only a `Claim`. They're buttons
  because the Stage *watches* for them.
- The Stage owns the state, in `Hold!`s keyed per frame, and exposes
  it as ordinary claims.
- The Play page is pure `When`: it reads the Stage's claims and
  wishes to display them. It has no state of its own.
- Nothing names another page by id; everything finds everything by
  what it claims to be.

That's the pattern to reach for whenever you build a tool in Folk:
claims for facts, wishes for effects, `When`s for reactions, and
`Hold!` only for the few things that must outlive the moment that
produced them.

## Appendix: every page in full

### Stage

```tcl
Claim $this is a stage

When $this has camera slice /slice/ {
    Wish $this displays camera slice $slice
}

if {[llength [Query! $this has frame count /n/]] == 0} {
    Hold! -key count Claim $this has frame count 0
}

When the image library is /imageLib/ &\
     /shutter/ is a shutter {
    ForEach! $this has camera slice /slice/ &\
             $this has frame count /n/ {
        set width [$imageLib Image_width $slice]
        set height [$imageLib Image_height $slice]
        set frame [$imageLib copyCrop $slice 0 0 $width $height]
        Hold! -key [list frame $n] \
            -destructor [list $imageLib imageFree $frame] \
            Claim $this has frame $n image $frame
        Hold! -key count Claim $this has frame count [expr {$n + 1}]
    }
}

When $this has frame count /n/ {
    Wish $this is labelled "$n frames"
    set last [expr {$n - 1}]
    When $this has frame $last image /im/ {
        Wish $this displays image $im with position {0 0} width 0.05
    }
}

When /eraser/ is a film eraser {
    ForEach! $this has frame /n/ image /im/ {
        Hold! -key [list frame $n] {}
    }
    Hold! -key count Claim $this has frame count 0
}
```

### Snap

```tcl
Claim $this is a shutter
Wish $this is labelled "SNAP"
Wish $this is outlined red
```

### Erase

```tcl
Claim $this is a film eraser
Wish $this is labelled "ERASE"
Wish $this is outlined white
```

### Play

```tcl
When /stage/ is a stage {
    When the collected results for [list $stage has frame /n/ image /im/] are /frames/ &\
         the clock time is /t/ {
        if {[llength $frames] == 0} {
            Wish $this is labelled "No frames yet"
            return
        }
        set ordered [lsort -integer -index 0 \
            [lmap f $frames {list [dict get $f n] [dict get $f im]}]]
        set fps 6
        set i [expr {int($t * $fps) % [llength $ordered]}]
        Wish $this displays image [lindex $ordered $i 1]
        Wish $this is labelled "frame $i of [llength $ordered]"
    }
}
```
