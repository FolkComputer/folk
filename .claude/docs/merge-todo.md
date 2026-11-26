# Upstream merge: changes still to port

The merge of `origin/main` (`587e2424`) into `smj-edison/zicl-testing` kept
our side wherever the two conflicted, so the branch keeps building and booting.
Git now considers everything below merged, so a later merge will _not_ bring
it back. This list is the only record of it.

To see what upstream did to a file, diff the merge base against upstream:

```sh
git diff 56c78b61 587e2424 -- <file>
```

Line numbers below are where our kept side sits in the merge commit, and will
drift as the files change.

## Whole files kept as ours

Upstream's lines in these files merged cleanly but depend on its new database
API, or on Jim, so the files were reset to our version wholesale. Port each as
a unit.

- `db.c`, `db.h`, `folk.c`, `sysmon.c`, `builtin-programs/collect.folk`:
  upstream moved destructor ownership into statement creation, so destructors
  are attached before a statement becomes queryable (commits `c8035cdc`,
  `2bdd4cf1`, `8aafe2cb`, `01325087`). `dbInsertOrReuseStatement` and
  `dbHoldStatement` take `destructor` and `inheritDestructorsFromMatch`;
  `HoldStatementGlobally!` takes a 9th `retainResources` argument; Collect
  versions its snapshots so an older query can't publish over a newer one;
  `workerReactivateOrSpawn` changed signature; and `folk.c` keeps a permanent
  cancellation handler. Ours uses `Zicl_List*` and `StatementContext`.
  - Already applied: `db.c`'s `__linux__` fix (`a733b3f0`), so match
    cancellation signals the right thread.
  - Stopgap: `HoldStatementGloballyFunc` accepts the 9th argument and ignores
    it (`TODO` in `folk.c`). Until this is ported, a capturing `Hold! {...}`
    doesn't keep its match's resources alive.
- `lib/python.tcl`: upstream closes the Python socket when the interpreter is
  freed (`Jim_SetAssocData`), adds `sockClose`, reconnects after a dropped
  connection, and sets `FD_CLOEXEC`. Ours keeps a per-thread socket table.

## Hunks kept as ours

Upstream's change in each hunk was dropped; the rest of the file merged.

- `boot.folk:9`: instance check is now an exclusive lock held on `folk.pid`
  for the process lifetime, instead of reading the PID. Needs file locking
  in zicl.
- `builtin-programs/apriltags.folk:138`, `:193`, `:241`: detector rework
  (`On unmatch` cleanup, restructured latest-detection loop, `AprilTag time`
  claim).
- `builtin-programs/calibrate/calibrate.folk:434`: upstream moved the solver
  (`processHomography` through the refined-calibration `Hold!`) into the new
  `calibrate/session.folk`, and ends collection with `calibration collected`
  and `collection completed run` claims instead. Ours still solves here. Once
  `session.folk` is ported, take upstream's tail and drop the linalg import at
  the top if nothing else uses it.
- `builtin-programs/calibrate/calibrate-page.folk:1`, `:111`, `:472`: page
  reworked for multiple cameras (`QUERY` `cameras`, per-camera previews,
  session progress).
- `builtin-programs/camera/slice.folk:8`, `:60`: geometry split into a
  `cameraSliceGeometry` helper, plus a `has camera slice with width` variant.
- `builtin-programs/camera/usb.folk:73`, `:287`, `:320`, `:380`, `:398`: new
  `Camera` struct and `CameraBuffer` frames (skips corrupt MJPEG frames),
  `getExposure`/`gainRange`/`setGain`, a default gain, and temporary-exposure
  wishes.
- `builtin-programs/terminal.folk:187`, `:200`, and `lib/terminal.tcl`
  (deleted upstream): upstream replaced the terminal with libghostty.
- `builtin-programs/web/apriltag-frame.folk:2`: `camera` query parameter.
- `builtin-programs/web/index.folk:6`: reads only the last 16 KB of program
  output. Needs `seek`/`tell` on zicl streams.
- `builtin-programs/web/web.folk:180`, `:306`, `:308`: `HtmlWhen` rework,
  including the stale `HtmlWhen` fix (`19e210fe`), and `handleRead` capturing
  `HtmlWhen` lexically.
- `lib/c.tcl:698`: 54 lines of upstream C prelude changes.

## Upstream code that merged in Jim syntax

These merged without conflict but are still Jim Tcl, so they fail when loaded.

- `builtin-programs/calibrate/session.folk` (new file): the calibration solver
  moved out of `calibrate.folk`, extended for multi-camera sessions.
- `builtin-programs/calibrate/refine.folk:503` onward: new `jointOptimize`,
  which returns a `Jim_Obj*`.
- `builtin-programs/terminal.folk`: the libghostty version (see above).
