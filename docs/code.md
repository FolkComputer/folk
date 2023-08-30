# What each file does...

1. `main.tcl`:
    1. Defines the Folk language
    2. Initializes Evaluator (statements, matches, tries)
    3. Provides Peers functionality to synchronize between machines
    4. Starts up the web-server
    5. Starts up the entry (laptop or pi)
2. `/pi`
    1. Functionality to setup the pi entry, e.g.
    2. Handling the camera input (`/pi/Camera.tcl`)
    3. Writing to the projector output (`/pi/Display.tcl`)
    4. Setting up keyboard events (`/pi/Keyboard.tcl`)
3. `laptop.tcl`
    1. Virtual program editor, each program is a window
    2. Also manages sharing between laptop and pi via `shareNode`
4. `vendor`
    1. Mostly Tcl libraries other people wrote (most or all are just
       copied from tcllib?). Except font.tcl, which is inlined C that
       other people wrote
5. `lib`
    1. Tcl/Folk libraries that we wrote, as well as the C FFI and the C trie
        - [`/lib/environment.tcl`](./lib/environment.md)
        - [`/lib/language.tcl`](./lib/language.md)
        - [`/lib/math.tcl`](./lib/math.md)
        - [`/lib/peer.tcl`](./lib/peer.md)
        - [`/lib/process.tcl`](./lib/process.md)
        - [`/lib/trie.tcl`](./lib/trie.md)

6. `virtual-programs`
    1. Our own high-level Folk programs
    2. They could be printed out... Perhaps, should be.
7. `play`
    1. TCL experiments
8. `calibrate.tcl`
    1. Calibrates the `pi` projector and dumps a bunch of homography metadata
       to disk
    2. Maybe should go into `/pi`? (I think the only reason it doesn't
       go in /pi is it's a runnable entry point and not a
       library. Maybe it could go into /pi and then we'd have `make
       calibrate` or something)
9. `replmain.tcl`
    1. A front-end to the statements database, like `laptop` or `pi`
    2. Should there just be a `/clients` directory, where all of the possible
       entries go, and live in parallel.
10. `host.tcl`
    1. Mapping from WiFi network, to name of Folk machines
