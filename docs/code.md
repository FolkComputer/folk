# What each file does...

1. `main.tcl`:
    1. Defines the Folk language
    2. Initializes Evaluator (statements, matches, tries)
    4. Starts up the web-server
    5. Starts up the entry (laptop or pi)
4. `vendor`
    1. Mostly Tcl libraries other people wrote (most or all are just
       copied from tcllib?). Except font.tcl, which is inlined C that
       other people wrote
5. `lib`
    1. Pure Tcl (and/or C) libraries that we wrote (need to be
       explicitly sourced into Folk & don't use Folk constructs),
       including the C FFI and the C trie
6. `virtual-programs`
    1. Our own high-level Folk programs
    2. They could be printed out... Perhaps, should be.
8. `calibrate.tcl`
    1. Calibrates the `pi` projector and dumps a bunch of homography metadata
       to disk
9. `replmain.tcl`
    1. A front-end to the statements database, like `laptop` or `pi`
    2. Should there just be a `/clients` directory, where all of the possible
       entries go, and live in parallel.
10. `host.tcl`
    1. Mapping from WiFi network, to name of Folk machines
