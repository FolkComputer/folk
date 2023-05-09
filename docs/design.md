## High-level design

Natural-language Datalog reactive database, implemented in a mixture
of Tcl and embedded chunks of C.

Statements (Claim, Wish, When) build a dependency graph that gets
incrementally updated as old statements are removed and new statements
are added.

(for example, every frame, old statements of AprilTag locations are
removed and new AprilTag locations are added, and everything
downstream of those locations will update)

Custom C 'FFI' is used to embed C in Tcl. Most hardware interface
(camera, projector/graphics rendering, soon keyboard) is done in
inline C that compiles and gets dynamically loaded at runtime.

Statements are indexed by a custom trie that goes word by word (also
implemented in C), so you can match with wildcards in any position in
a statement.

## Why Tcl? (from question on Discord, WIP)

Tcl question i've wanted to write about before. it's a little bit
accidental in that the current system grew out of a bunch of older Tcl
and C prototypes.

I think for a system like this, you want a language with extensible
syntax (that can at minimum express the natural-language-Datalog
constructs as fluently as built-in language constructs) and that has
decent interop with C. Tcl fits the bill pretty well. (and it has a
GUI toolkit and a bunch of other niceties)

Lua, LuaJIT, some Scheme variant, Duktape, or QuickJS would probably
be ok, with different tradeoffs for each (Lua and JS you don't get
syntax extensibility out of the box so you need to do that yourself,
in Lua you have to hook the parser, you'd have to make sure your new
constructs compose ok with built-in constructs etc, it's hard to
iterate on them; a lot of JS runtimes like Node have terrible C
interop stories so you'd have to be a wizard to do that stuff; Scheme
you probably don't want to be writing on a bare-bones tabletop editor;
etc)

oh, and Tcl also has very good threading, much better than any other
scripting language; i think that's actually a really big plus. (this
is for a few reasons -- all Tcl datatypes and code are easy to
network-serialize and ship around, the syntax for embedded Tcl code is
nice since it's just a multiline string, Tcl has a good built-in
multithreading library)

in general, Tcl also supports the 'polyglot' way of doing things
pretty well, where you can have different sublanguages embeded into
your Tcl code just inside curly braces.

### Non-goals (WIP)

- ability to reuse existing API knowledge (HTML/DOM, JS canvas,
  terminal I/O): none of this behavior is idiomatic for physical
  computing

- portability to Web: if you're setting up a camera and projector rig
  in your space, you are probably willing to run a native app
