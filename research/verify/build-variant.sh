#!/bin/sh
# Builds an instrumented copy of the folk binary next to the normal one,
# without touching the objects of the normal build.
#
#   research/verify/build-variant.sh tsan  -fsanitize=thread
#   research/verify/build-variant.sh asan  -fsanitize=address,undefined
#   research/verify/build-variant.sh tracy -DTRACY_ENABLE
#
# Run from the repository root. The result is research/verify/build/NAME/folk
# and must be run from the repository root too, like ./folk.
set -e
name=$1; shift
out=research/verify/build/$name
mkdir -p "$out"

cflags="-O1 -g -fno-omit-frame-pointer -D_GNU_SOURCE -U_FORTIFY_SOURCE $*"
linker=cc
extra=""
case " $* " in *" -DTRACY_ENABLE "*)
    # Same as the Makefile: the Tracy client is C++.
    if [ ! -f "$out/TracyClient.o" ]; then
        c++ -c -O2 -g -std=c++20 -DTRACY_ENABLE -fno-omit-frame-pointer \
            -o "$out/TracyClient.o" vendor/tracy/public/TracyClient.cpp
    fi
    extra="$out/TracyClient.o"
    linker=c++
    cflags="-O2 -g -fno-omit-frame-pointer -D_GNU_SOURCE -U_FORTIFY_SOURCE $*"
    ;;
esac

objs=""
for src in workqueue.c db.c trie.c sysmon.c epoch.c folk.c \
           output-redirection.c block-stats.c \
           vendor/c11-queues/mpmc_queue.c vendor/c11-queues/memory.c; do
    obj="$out/$(basename "$src" .c).o"
    cc -c $cflags -Wl,--export-dynamic -I./vendor/jimtcl -I./vendor/tracy/public \
        -o "$obj" "$src"
    objs="$objs $obj"
done
# Record the flags where the runtime C compiler (lib/c.tcl) does not look,
# so the in-tree CFLAGS file of the normal build is left alone.
$linker -g -fno-omit-frame-pointer $* -Wl,--export-dynamic -o "$out/folk" \
    $objs $extra -L./vendor/jimtcl -ljim -lm -lssl -lcrypto -lz
echo "built $out/folk"
