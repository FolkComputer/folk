# Folk

Folk is being ported from a Jim Tcl-based interpreter to a custom one,
**zicl** (`vendor/zicl`, its own Zig project/git repo). This file exists
mainly to explain zicl's module/scoping system, since it's easy to get
wrong by assuming it works like real Tcl.

## The module system

There are no real Tcl namespaces. `namespace eval`, `namespace import`,
`proc`, `package require` -- none of that exists in zicl. Code (including
vendored Tcllib packages under `vendor/`) written against real namespaces
needs to be ported, not just re-pointed at new names.

### `::` is not special

In real Tcl, a leading `::` means "the absolute global namespace." In
zicl, `::` has **no special meaning at all** -- it's just two characters
that can appear in a variable or command name, like any other character.
`$::TAU` is a lookup for a variable literally named `::TAU`; if nothing by
that exact name exists, it's a plain "no such variable" error, not a
global-namespace read. This is a real trap: code ported from the old
interpreter that says `$::something` almost always needs to become
`$something` or `$module::something`, not be left alone.

### Dict-sugar: how "modules" are actually represented

`foo::bar::baz` as a variable (or command) name is sugar for: look up the
dict-valued variable `foo`, then walk keys `bar`, `baz` inside it.
`set math::PI 3.14` sets key `PI` in the dict variable `math`. This is a
completely generic mechanism (`vartypes.DictSugar`), not something
special-cased per module -- `env::HOME`, `math::PI`, `cc::proc` all work
this way.

Commands and variables share one lookup path: resolving a command name
*is* a variable lookup, and a value is callable if it holds a closure (or
the special `nativefn <name>` marker for built-ins). So `fn math::square
{x} {...}` and calling it as `math::square 4` both go through the exact
same dict-sugar machinery as `$math::square` would for a plain value.
There's no separate "namespace" registry.

Consequence: native builtins (`fn`, `set`, `expr`, `dict`, ...) aren't
magically available everywhere -- they're bootstrapped as `nativefn ...`
values in the *root* call frame (frame 0), reachable only if a scope's
`~parent` chain eventually leads back to it. A truly unparented scope
can't even resolve `set`.

### Closures capture scope lexically, at definition time

`fn {args} {body}` captures whatever's in scope *where `fn` is called*
(`Interp.captureCurrentScope`), the same way a JS closure captures its
enclosing scope -- not "which namespace this code lives in." Every
*call* of a closure gets its own fresh local frame (a `VarTable`); `set`
inside that call writes to that frame, not to the captured parent, and
that frame is discarded when the call returns (unless something inside
it creates a nested closure that captures it, extending its life via
refcounting). This matches real Tcl `set`-inside-a-proc semantics: you
never implicitly write through to an enclosing scope.

Why top-level definitions in a sourced file "stick": `source` (and plain
`eval`) does **not** push a new call frame -- it runs in the caller's own
frame. `boot.folk` runs inside one persistent frame (`run`'s), so
anything it `source`s (`lib/math.tcl`, etc.) lands its `set`/`fn`
definitions directly into that frame. That frame then stays alive
indefinitely because virtually every closure created anywhere in the
system, directly or transitively, captures a scope chain that leads back
to it -- so it behaves like a de facto global namespace, even though
architecturally it's "just" one captured frame.

### `import` / `dict assign`

For writing an actual module file that shouldn't just dump its names into
whatever scope happens to `source` it, use `import` + `dict assign`
instead:

```tcl
set linalg [import lib/linalg.tcl]
dict assign $linalg add sub scale matmul
```

- `import path` reads the file and evaluates it in a **fresh call frame**
  of its own. That frame's scope is a capture of the *caller's* current
  scope (same as if the file's contents were the body of `fn {} {...}`
  written right at the `import` call site) -- so the file still sees
  ambient globals, but its own top-level `set`/`fn` definitions land in
  its own frame, not the caller's. Before that frame is torn down, its
  bindings are captured into a dict and returned -- *instead of* the
  file's normal return value. That dict is the module's value.
- `dict assign dictValue name1 ?name2 ...?` pulls specific keys out of a
  dict into local variables -- like `lassign`, but by key instead of
  position. Errors if a requested key doesn't exist.

This is the closest analogue to `namespace import` this system has: no
real namespace, so no implicit "current namespace" magic -- you get an
explicit module value back from `import` and explicitly pull the names
you want out of it.

Write new modules meant for `import` as flat files (`fn add {...}`,
`fn sub {...}`, no `::` qualification) -- since they all land in one
frame together, unqualified sibling calls just work, unlike trying to
replicate real Tcl namespace-scoped command resolution.
