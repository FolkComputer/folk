#!/bin/sh
# Builds a copy of folk with one of the what-if patches applied, without
# touching the sources in the tree.
#
#   research/bench/build-whatif.sh idle-backoff
#
# The result is research/verify/build/whatif-NAME/folk. The patches are
# experiments to size an opportunity, not proposed changes.
set -e
name=$1
out=research/verify/build/whatif-$name
rm -rf "$out"; mkdir -p "$out/src/vendor/c11-queues"
for f in *.c *.h; do cp "$f" "$out/src/"; done
cp vendor/c11-queues/*.c vendor/c11-queues/*.h "$out/src/vendor/c11-queues/"
cp vendor/stb_ds.h "$out/src/vendor/"
(cd "$out/src" && patch -s -p0 < ../../../../bench/patches/$name.patch)

objs=""
for src in workqueue.c db.c trie.c sysmon.c epoch.c folk.c \
           output-redirection.c block-stats.c \
           vendor/c11-queues/mpmc_queue.c vendor/c11-queues/memory.c; do
    obj="$out/$(basename "$src" .c).o"
    cc -c -O2 -g -fno-omit-frame-pointer -D_GNU_SOURCE -U_FORTIFY_SOURCE -w \
        -I"$out/src" -I./vendor/jimtcl -I./vendor/tracy/public -o "$obj" "$out/src/$src"
    objs="$objs $obj"
done
cc -g -fno-omit-frame-pointer -Wl,--export-dynamic -o "$out/folk" $objs \
    -L./vendor/jimtcl -ljim -lm -lssl -lcrypto -lz
echo "built $out/folk"
