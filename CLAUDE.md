# Folk

Folk is being ported from a Jim Tcl-based interpreter to a custom one,
**zicl** (`vendor/zicl`, its own Zig project/git repo). This file exists
mainly to explain zicl's module/scoping system, since it's easy to get
wrong by assuming it works like real Tcl. Note that we're co-developing
Zicl with Folk, so if you hit a bug, it's probably best to fix it in the
interpreter.

## The module system

There are no real Tcl namespaces. [namespace eval], [namespace import],
[proc], [package require] -- none of that exists in zicl. Code (including
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

Consequence: native builtins ([fn], [set], [expr], [dict], ...) aren't
magically available everywhere -- they're bootstrapped as `nativefn ...`
values in the *root* call frame (frame 0), reachable only if a scope's
`~parent` chain eventually leads back to it. A truly unparented scope
can't even resolve [set].

Second consequence, and the one that actually bites: a local variable
shadows the builtin of the same name for the rest of the frame. [foreach]
and [lmap] loop variables are the usual way in, since they stay bound
after the loop ends:

```tcl
lmap {fnName fn} $someDict { ... }  ;# `fn` now holds the last value
fn emitThing {} { ... }             ;# ...so this is "not a valid function"
```

The failure surfaces wherever the shadowed name is next *called*, which
can be a long way from the loop -- in `gpu/pipelines.folk` it was a [fn]
inside a later `$[...]` block, blamed on a three-line anonymous script.
Worth avoiding as local or loop variable names: [fn], [set], [if], [for],
[dict], [list], [string].

### Closures capture scope lexically, at definition time

`fn {args} {body}` captures whatever's in scope *where [fn] is called*
(`Interp.captureCurrentScope`), the same way a JS closure captures its
enclosing scope -- not "which namespace this code lives in." Every
*call* of a closure gets its own fresh local frame (a `VarTable`); [set]
inside that call writes to that frame, not to the captured parent, and
that frame is discarded when the call returns (unless something inside
it creates a nested closure that captures it, extending its life via
refcounting). This matches real Tcl [set]-inside-a-proc semantics: you
never implicitly write through to an enclosing scope.

That capture is a *snapshot, by value*, taken at the moment [fn] runs.
Three things follow, each of which reads as a bug the first time you hit
it:

```tcl
fn rec {n} { if {$n <= 0} { return done }; rec [- $n 1] }
rec 3                    ;# invalid command name "rec"

fn a {} { b }
fn b {} { return B }
a                        ;# invalid command name "b"

set z 1; fn c {} { return $z }; set z 2
c                        ;# 1, not 2
```

A function can't see itself, can't see a sibling defined below it, and
never observes a later write to a variable it captured. Order your
definitions accordingly. For a self-recursive one, define it into a scope
of its own and hand it back out through [letrec select]:

```tcl
fn recscope::rec {n} { if {$n <= 0} { return done }; rec [- $n 1] }
set rec [letrec select $recscope rec]
```

[letrec select] makes the scope's keys resolvable as bare names inside the
call, and `Interp.captureScope` re-wraps each of them as its own `letrec
select` for any closure created during that call -- so a recursive call
from inside a nested `When` body resolves too. `gpu/draw.folk`'s
`compileScope` is the worked example.

Why top-level definitions in a sourced file "stick": [source] (and plain
[eval]) does **not** push a new call frame -- it runs in the caller's own
frame. `boot.folk` runs inside one persistent frame (`run`'s), so
anything it sources (`lib/math.tcl`, etc.) lands its [set]/[fn]
definitions directly into that frame. That frame then stays alive
indefinitely because virtually every closure created anywhere in the
system, directly or transitively, captures a scope chain that leads back
to it -- so it behaves like a de facto global namespace, even though
architecturally it's "just" one captured frame.

### [import] / [dict assign]

For writing an actual module file that shouldn't just dump its names into
whatever scope happens to [source] it, use [import] + [dict assign]
instead:

```tcl
set linalg [import lib/linalg.tcl]
dict assign $linalg add sub scale matmul
```

- `import path` reads the file and evaluates it in a **fresh call frame**
  of its own. That frame's scope is a capture of the *caller's* current
  scope (same as if the file's contents were the body of `fn {} {...}`
  written right at the [import] call site) -- so the file still sees
  ambient globals, but its own top-level [set]/[fn] definitions land in
  its own frame, not the caller's. Before that frame is torn down, its
  bindings are captured into a dict and returned -- *instead of* the
  file's normal return value. That dict is the module's value.
- `dict assign dictValue name1 ?name2 ...?` pulls specific keys out of a
  dict into local variables -- like [lassign], but by key instead of
  position. Errors if a requested key doesn't exist.

This is the closest analogue to [namespace import] this system has: no
real namespace, so no implicit "current namespace" magic -- you get an
explicit module value back from [import] and explicitly pull the names
you want out of it.

Write new modules meant for [import] as flat files (`fn add {...}`,
`fn sub {...}`, no `::` qualification) -- since they all land in one
frame together, unqualified sibling calls just work, unlike trying to
replicate real Tcl namespace-scoped command resolution. Subject to the
snapshot rule above: a helper has to be defined before the function that
calls it, not after.

## [expr] comparisons are strict -- intentionally not backwards-compatible

In real Tcl (and JimTcl), `==`/`!=`/`<`/`>`/`<=`/`>=` fall back to a
lexicographic string compare when an operand isn't a valid number, so
`expr {"foo" == "bar"}` quietly works. zicl does **not** do this: those
operators are strictly numeric, and comparing a non-numeric operand is an
error ("expected float but got ..."). This is a deliberate design choice,
not a gap to "fix" by porting Tcl's fallback behavior -- implicit casting
in comparisons is a footgun. Code that means string comparison should say
so explicitly with `eq`/`ne`/`lt`/`gt`/`le`/`ge`.

Booleans (`true`/`false`) are also intentionally **not** numbers, and are
kept distinguishable from `0`/`1`. The one exception: `==`/`!=` (and
only those two operators) special-case boolean-vs-boolean comparison,
where a string operand must be spelled exactly `true`/`false`:

```tcl
expr {true == true}      ;# true
expr {true == "false"}   ;# false
expr {true == 1}         ;# error: expected float but got "true"
```

Anything else falls through to the strict numeric path and errors as
usual, rather than silently coercing. zicl code relying on Tcl's loose
comparison semantics (e.g. `==` between two arbitrary strings, or a
boolean compared against a non-boolean) is a bug in the *calling* code
to fix, not a signal to add a compatibility fallback to [expr] itself.

## Porting table: Jim Tcl to zicl

What the old interpreter accepted, and what it becomes here. Most of these
fail loudly, but the first two rows fail in ways worth knowing about: an
`==` against a non-numeric operand raises, while `sscanf`-based numeric
conversion silently reads `0x07230203` as `0`.

| Jim Tcl                            | zicl                                    |
|------------------------------------|-----------------------------------------|
| `expr {$a == $b}` on strings       | `eq` `ne` `lt` `gt` `le` `ge`           |
| `$::x`                             | `$x`                                    |
| `puts $fd $x`                      | `stream write $fd "$x\n"`               |
| `dict with $d {body}`              | `dict assign -all $d` then the body     |
| `namespace eval foo {...}`         | dict sugar: `fn foo::bar {...}`         |
| `library create n {statics} {...}` | a plain dict plus `fn lib::name {...}`  |
| `variable x`                       | nothing; enclosing scope is lexical     |
| `variable x $v`                    | `set x $v`                              |
| `return -code $n` + `on $n`        | `error $msg $errorCode` + `trap`        |
| `$ensemble sub $args`              | `ensemble::sub $args`, a dict of fns    |
| `{*}$closure`                      | `closure` -- call the variable by name  |
| `info commands "$lib *"`           | `dict keys $lib`                        |

A closure held in a variable is called by writing that variable's bare
name as the command word, since commands and variables share one lookup
path -- `$closure` would read its value instead, and splatting that spells
the closure's string form out as words. [apply] is for when the closure is
the result of an expression rather than a variable, as in
`apply [dict get $lib handler] $arg`.

Two of these are about shape rather than spelling. `dict assign -all`
binds only the keys the dict actually holds, which is what makes it a
stand-in for [dict with]: an `if {![info exists layer]}` guard downstream
keeps working. And [trap] matches on an error code, so a `return -code 99`
signal becomes `error "..." [list MY DOMAIN $detail]` paired with
`trap {MY DOMAIN} {_ opts}`, reading the detail back out of
`[dict get $opts -errorcode]`.

## Style guide
-   Write for a reader who is fluent in low-level programming, but only has a high level understanding of this project, and who was not present for the discussion that produced the code actively being written. Assume they can read Zig and reason about atomics, ownership, and memory layout. Do not assume they know why some alternative was rejected, what a symbol used to be called, which bug prompted a line, or what any of it looked like an hour ago. A comment that only makes sense to someone who watched the code being written is scratch work, not documentation.
-   Write Tcl as Tcl, not TCL.
-   Prefer commas or parenthesis over em-dashes. Also, write in ASCII characters exclusively (i.e. no — or →). Double hypens, --, can substitute for a proper em dash.
-   Use "why" commands, and occasional "how" comments, but avoid "what" comments unless the logic is dense.
-   Split a function's comments by what the reader needs. The doc comment on the signature says how to call it: what it takes, what it gives back, what the caller is then responsible for, plus whatever rationale a caller has to know to use it correctly. Everything about _how_ it works goes in the body, next to the code it explains. A signature that opens with three paragraphs on lock ordering is telling callers something they cannot act on and burying it from the person changing the implementation.
-   Comment the exceptions, not the conventions. If a reader who knows this codebase would already predict what a line does, leave it alone; spend the comment where the code departs from what they'd predict. This is the "what" comment rule applied to design rules rather than to syntax: that `interp.getInteger` reports its own errors is the convention and needs no note, whereas a call site that deliberately bypasses it does.
-   Seek for brevity in all comments. Unnecessary details and only tenously related points make it harder to follow.
-   Give a complicated edge case a concrete example, in a triple-backtick block under the prose that introduces it (see `DictSugar` in `src/vartypes.zig`). If a comment describes a situation the reader has to construct in their head (an aliased variable, a shared object, a specific argument shape), show the two or three lines of Tcl that produce it. An edge case worth an example is usually also worth a test.
-   End every comment with a period, exclaimation point, or similar (what's important is that the thought is properly terminated).
-   Don't use UPPERCASE, instead use _emphasis_. TODO, FIXME, PERF, HACK, etc are exceptions to this rule, as they're used for grepping.
-   If there's a short `if (optional) |val|`, use `val` as the capture name, not `h`.
-   Avoid using overly terse names, like `ef` for an evaluation frame. Use something like `frame` or `eval_frame` instead. Use `err` instead of `e` as well.
-   Follow the known-new contract when writing: every sentence, always introduce something that the reader has previously read before introducing something new.
-   Whenever you refer to a variable or a piece of code, enclose it in backticks. Exceptions to this rule include integer types (i.e. i64, u5), error types (i.e. error.OutOfMemory), and command/subcommand names surrounded by brackets (e.g. [puts], not `puts`).
-   Don't remove comments when porting code. There's been multiple instances where code lost important comments during porting or refactoring. It makes it unnecessarily hard to reason about.
-   Make sure comments don't include internal thought processes or references to temporary state. Comments should be written for future readers of the code, not for scratch work.
-   Don't leave comments behind after fixing ownership/ref counting bugs, unless it's significantly outside of normal ownership patterns. They quickly balloon out of control and make the code incomprehensible. See "don't make comments with internal thought process."
-   Minimize parenthetical asides, as it makes the writing hard to follow. Do your best to have a linear structure with your sentences.
