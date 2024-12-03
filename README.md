# db

```
$ cd vendor/jimtcl && ./configure CFLAGS=-g && cd -
$ make deps
```

then

```
$ make && ./folk
```

or

```
$ make remote FOLK_REMOTE_NODE=folk-live
```

Init and update the submodule & you can pass `CFLAGS=-DTRACY_ENABLE`
to `make` for Tracy.

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
- match or statement arena allocator
  - for camera images, at least
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
- blinking on folk0
- **fix memory leak (5MB/second)**
  - cache per-thread value copies?
