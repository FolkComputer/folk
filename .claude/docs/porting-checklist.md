# zicl porting checklist

Tracking what's left in the Jim Tcl -> zicl port. See CLAUDE.md for the
semantics that keep biting.

## `dict with` -> `dict assign -all` -- done (21 sites)

All converted. `dict with` ran its body in the caller's own frame and bound
every key there, and `dict assign -all` does the same, so the shadowing
behaviour is unchanged. The one real difference is the writeback, which two
sites depended on and now do explicitly:

- `apriltags.folk:203` mutated `c` and `p` and then did `lappend tags $tag`.
- `tags-to-quads.folk:456` mutated `frozen`/`frozenPose`/`unfreezeTime` and then
  claimed `$state`. Note `tagPose` is deliberately *not* written back there: it
  belongs to the enclosing scope rather than to `$state`.

The five in `gpu/draw.folk` and `gpu/canvases.folk` name their keys explicitly
instead of using `-all`. That is deliberate, not unfinished: naming keys turns a
typo into an error rather than a silently missing variable.

## `puts $fd x` -> `stream write $fd "x\n"` -- done (11 sites)

Single-argument `puts $x` writes to stdout and stays as it is; only the
two-argument channel form broke, since zicl's [puts] takes no channel but
`stderr`. Converted in `gpu/pipelines.folk`, `gpu/toy-shader.folk`,
`print/print.folk` (3), `editor/print-editor.folk`, `esc-pos.folk` (2),
`music.folk` (2), and `calibrate/calibration-board.folk`.

[flush] turned out not to be needed: `stream write` goes through
`writeAndFlush`, so it flushes on every write. The one call, at
`music.folk:175` against the ghci FIFO, is just gone.

`music.folk`'s multi-line brace literal moved its closing `}` onto its own line
so the literal itself carries the trailing newline [puts] used to append.

## Blocked or deferred

- [ ] `lib/ws.tcl` -- unported: `$cc` method syntax and `Jim_Obj` callbacks.
      Blocked on socket support landing in zicl.
- [ ] `builtin-programs/terminal.folk:26` -- FIXME marker, does not run.
- [ ] `lib/terminal.tcl:141` -- still `library create`.
- [ ] `lib/json.tcl` decodes by tokenizing with one [regexp] pass and walking
      the token list. Fine for the payloads seen so far, but sam2 and craft can
      return large arrays; revisit if it shows up in a profile. `-index` and
      `-schema`, which jimtcl's decoder took and nothing in Folk used, are
      absent rather than silently accepted.
- [ ] `UvxCleanup` in `lib/python.tcl` still shells out to `kill`/`pkill` with
      `$pid`, but under zicl that is a process *capability*
      (`<zicl://host/process/...>`), not a number. `[pid $capability]` already
      returns the numeric pids, so no new zicl helper is needed. It also calls
      [after], which zicl does not have, to escalate TERM to KILL after a
      second. Spawning uvx in its own process group would be the sturdier fix,
      since one signal to the group would replace the `pkill -P` dance
      entirely.
- [ ] zicl has no `{argList body}` lambda: [apply] takes a closure only, so
      `apply {{im} {...}}` fails. Three sites in `builtin-programs`
      (`programs.folk:67`, `tags-to-quads.folk:391,396`) and several in
      `user-programs`. Either support the two-element form in [apply] or
      convert the call sites to [fn].
- [ ] `zicl/src/commands/regex.zig:411` -- `regsubCmd` leaks via
      `String.newOwningNoFree`.
- [ ] Folk leaks temp files into `/tmp` on every boot, and `/tmp` is a 7.5G
      tmpfs here, so it is not free. Two separate leaks:
      - `set f [file tempfile /tmp/cfileXXXXXX].c` creates `/tmp/cfileXXXXXX`
        via mkstemp and then writes `/tmp/cfileXXXXXX.c`, orphaning the empty
        original. Same shape in `glslc`'s `.glsl`. Nearly a thousand zero-byte
        files had piled up.
      - The `.c`, `.o`, and `/tmp/$cid.so` are never removed: ~32MB per handful
        of boots.

## Landed this round

zicl:

- `vartypes.zig:510` -- `dictSugarReadInner` wrote the shimmered `dict_name`
  back with `Value.swap` (which takes ownership) and then `discardChanges`
  dropped that same reference, leaving `dict_sugar.dict_name` dangling. Cached
  `foo::bar` lookups intermittently read freed memory. Now `takeShimmered()`.
- `include/libzicl.h` -- `Zicl_GetPointerCapability` was declared with three
  parameters against a four-parameter export, so every generated `cc::proc`
  taking a `Foo*` left `out_head` as register junk and wrote through it.
- `try_catch.zig` -- `trap` matched any error carrying no `-errorcode`.
- `list.zig` -- added `lsearch -all`.
- `dict.zig` -- added `dict assign -all`; zero key names is now a no-op rather
  than an error, so `{*}$names` on an empty list works.
- `io.zig:329` -- `file readable` errored on `AccessDenied` instead of
  answering false.
- `Interp.zig` -- `nextRandomFloat` built its divisor and numerator with
  `@bitCast` where it needed `@floatFromInt`, so the divisor was negative zero
  (`0x8000...` *is* -0.0) and the numerator was random bits read as a double.
  Every `rand()` returned an infinity.
- `expr_parse.zig` -- `renderInner` grouped nullary `.rand` with the unary
  functions and rendered an operand for it, recursing on whatever `data.unary`
  held. Any `expr` error whose parse tree contained `rand()` overflowed the
  stack (~32k frames), which is what `python.tcl:219`'s
  `int(rand() * 100000)` hit.
- `objects.zig` -- `getKvPairs` released the rewritten `~parent` HashReference
  only on the error path, so following a link leaked the whole parent chain.
  `dict keys`/`values`/`size`/`assign -all` on a linked dict all hit it; no test
  had exercised that path before.

Folk:

- `Tokenizer.zig` -- two divergences from Jim around a `"` that is not at the
  start of a word, both found porting json. In `nextStringToken` the non-opener
  case neither consumed the quote nor treated it as an opener, so the scanner
  spun on that character forever. In `nextCommandToken`, `start_of_word` was
  recomputed only in the `else` arm, so an escape left it set and the quote in
  `\\"` tried to open a quoted word; `JimParseSubCmd` recomputes it at the
  bottom of the loop for every character, which is what clears it. Both now
  match Jim byte for byte on `set a \\"` and on `list \\ \\\\ \" \\"`.
- `lib/json.tcl` is new: `json::encode` is a near-verbatim port of jimtcl's
  `jsonencode.tcl`, and `json::decode` is a fresh implementation of the same
  surface (the original was a C wrapper around jsmn). Both live in one
  [letrec select] scope, since `subencode` recurses and the parser is mutually
  recursive. Two places needed more than transcription: `bool` leant on Tcl
  truthiness, which zicl does not have, and `\uXXXX` decoding is mandatory
  rather than optional because the Python harness calls `json.dumps` with its
  default `ensure_ascii`. The encoder's escape map is otherwise verbatim.
- `lib/python.tcl` is off `library create`: a plain dict of closures, with the
  per-thread socket moved into C (`sockForEndpoint`, `_Thread_local`) beside
  the per-endpoint state that was already there, and `def` reworked into a
  [method] so its writeback binds the new function as a real key in the
  caller's dict. That drops the need for a per-dict [unknown]. The argtype
  serializer is now a closure rather than a code string, since zicl's [apply]
  has no `{argList body}` form; it round-trips through the C slot as its
  string, scope hash and all. Verified as far as the Python round trip: the
  worker spawns, `pyExec` reaches it, and the failure is now decoding the
  reply.
- `lib/text.tcl` -- `==` against a string, and a leading `::` on a call.
- `apriltags.folk` -- dropped a dead `namespace import ::math::min ::math::max`;
  both are plain `fn`s in `lib/math.tcl` already.
- CLAUDE.md gained a Jim-Tcl-to-zicl porting table, a note that a local (or
  leftover loop) variable shadows the builtin of the same name for the rest of
  the frame, and a note that `fn` snapshots its scope by value, so recursion
  needs `letrec select`. Command names throughout now use Tcl's `[cmd]`
  convention rather than backticks.
- 61 sites across 26 files where an earlier pass had mangled `"$X "` into
  `"X::"` (`p0::$p1`, `projectorName::\`, `fnRtype::$fnName`,
  `width::== $usingOpts::width`). One site matching that shape was legitimate
  dict sugar and is untouched: `gpu/canvases.folk:409`.
- `lib/c.tcl` -- `C::extend` re-marked copied snippets `:noextend`, so a struct
  typedef only propagated one level; a two-level extend inherited an objtype's
  marshaling code without its `typedef`. Also routed the `uint16_t`/`uint32_t`
  argtypes through `Zicl_GetLong`: they used `sscanf("%PRIu32")`, which silently
  reads glslc's `0x07230203` as 0, and the `uint16_t` one passed an `int*` to a
  `long*` parameter.
- `gpu/textures.folk:81` -- a `static` forward declaration gave the `cc::proc`
  definition internal linkage, so `dynlib lookup` could not find it.
- The pipeline compiler moved off `library create` onto `fn
  pipelineCompilerLib::...`, and `gpu/draw.folk`'s `makeGpu` collapsed to
  `set gpu $drawLib`.
