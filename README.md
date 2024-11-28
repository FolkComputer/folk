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
- consistent name for sustain/ttl/remove-later
- reap threads that got caught up on some long-running activity so
  that we aren't just monotonically growing thread count
- event statements
- **fix memory leak (5MB/second)**
  - cache per-thread value copies?
- match or statement arena allocator
  - for camera images, at least
- performance analysis
  - perf/speedscope
  - have some kind of label-based, cross-thread fps counter
  - **pmap monitor for memory leak?**
- clean up shader reference errors (use trick from main?)
- **fix camera-rpi corruption**
- ~~port tag iters fix from folk1~~
- ~~web stops working after a while~~
- **marching ants animation**
- ~~blinking of outlines~~
  - still some blinking, need to adjust metastable timing
- ~~sticking of outlines~~
- is stealing too frequent? are we spending most of our time trying to
  steal?
- ~~incremental tag detector~~
- ~~60Hz camera~~
- ports
  - keyboard/editor port
  - points-up port
  - calibration process
- ~~infinite loop or one-lane syntax? one-at-a-time~~
- Hold! with explicit version number?
- ~~reuse C module so perf events hold~~
- report errors as statements
- ~~spinlock~~
- **fix bottleneck around global queue lock dominating flamegraph**
  - i think we're getting scheduled off CPU with the lock held
- wait until process death to start
