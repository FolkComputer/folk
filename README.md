# db

```
$ cd vendor/jimtcl && ./configure CFLAGS=-g && make && cd -
$ make && ./folk
```

## todo

- preserve stack traces
- ~~put C procs on C compiler object instead of global namespace~~
- ~~deal with macOS/glfw needing to be on thread 0?~~ ish
- ~~port webcam~~
- ~~port apriltag~~
- ~~port display~~
- C objects accessible across When boundary?
  - plan: use unknown to catch calls to refs?
  - inculcate ref with thread id? lock ref hashtable in foreign
    process, make proxy with C functions? this is so weird
  - make ref ids bigger?
- implement Collect -> labels
  - use some sort of timer?
- thread monitoring (what threads are running what? what threads are blocked?)
- spin up new threads if most/all existing threads are OS-blocked
- event statements
- ~~transactions, causality, or Commit~~ Hold!
- fix segfault (memory leak?) after a while
- performance analysis

