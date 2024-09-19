# db

```
$ cd vendor/jimtcl && ./configure CFLAGS=-g && make && cd -
$ cd vendor/apriltag && make libapriltag.a libapriltag.so && cd -
$ make && ./folk
```

## requirements

on Debian bookworm amd64: `psmisc`, `build-essential`, `git`,
`libssl-dev`, `zlib1g-dev`, `libjpeg-dev`, `glslc`, `libwslay-dev`

for debugging: `elfutils` (provides `eu-stack`)

## todo

- ~~preserve stack traces~~
  - adjust stack record if When is multiline
- ~~put C procs on C compiler object instead of global namespace~~
- ~~deal with macOS/glfw needing to be on thread 0?~~ ish
- ~~port webcam~~
- ~~port apriltag~~
- ~~port display~~
- ~~thread-local workqueues & work stealing~~
  - dependencies? transactions?
- fix printing to stdout
- clock time?
- When priorities? deadlines?
- ~~C objects accessible across When boundary?~~
  - ~~plan: use unknown to catch calls to refs?~~
  - ~~inculcate ref with thread id? lock ref hashtable in foreign
    process, make proxy with C functions? this is so weird~~
  - ~~make ref ids bigger?~~
- ~~implement Collect -> labels~~
  - use some sort of timer?
- ~~thread monitoring (what threads are running what? what threads are blocked?)~~
- spin up new threads if most/all existing threads are OS-blocked
  - reuse old thread slots
- ~~destructors~~
- event statements
- ~~transactions, causality, or Commit~~ Hold!
- fix segfault (memory leak?) after a while
  - ~~garbage collect on list resize~~
  - free Clauses (lifetime tied to statements?)
- cache statements on each interpreter
- performance analysis
  - perf/speedscope
  - have some kind of label-based, cross-thread fps counter
  - RAM monitor
- clean up shader reference errors (use trick from main?)
