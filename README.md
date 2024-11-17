# db

```
$ cd vendor/jimtcl && ./configure CFLAGS=-g && make && cd -
$ cd vendor/apriltag && make libapriltag.a libapriltag.so && cd -
$ make && ./folk
```

## requirements

on Debian bookworm amd64: `psmisc`, `build-essential`, `git`,
`libssl-dev`, `zlib1g-dev`, `libjpeg-dev`, `glslc`, `libwslay-dev`, `console-data`

for debugging: `elfutils` (provides `eu-stack`), `google-perftools`,
`libgoogle-perftools-dev`

## todo

- adjust stack record if When is multiline
- ~~thread-local workqueues & work stealing~~
  - dependencies? transactions?
- fix printing to stdout
- clock time?
  - hold it in sysmon?
  - **-> marching ants animation**
- When priorities? deadlines?
  - consistent name for sustain/ttl/remove-later
- ~~implement Collect -> labels~~
  - use some sort of timer?
- reap threads that got caught up on some long-running activity so
  that we aren't just monotonically growing thread count
- event statements
- **fix memory leak (200MB/second)**
  - cache per-thread value copies?
- **workqueues get really huge??** is this the cause of leak?
- performance analysis
  - perf/speedscope
  - have some kind of label-based, cross-thread fps counter
  - **pmap monitor for memory leak?**
- clean up shader reference errors (use trick from main?)
- **fix camera-rpi corruption**
- port tag iters fix from folk1
- weird bugs
  - drawImpl crash (vkCmdBindPipeline -> out of range) (does this
    happen when RAM is under 100MB always?)
- enforce removal of two-generation-old Holds so you don't blow up

