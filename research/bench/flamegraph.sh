#!/bin/sh
# Profiles one run of a Folk program the way `make flamegraph` profiles a
# running system: perf sampling at 997 Hz with call graphs, folded by
# FlameGraph's scripts. Two differences forced by the VM this was written
# on: the event is the software cpu-clock (no hardware PMU), and the call
# graphs come from frame pointers (no LBR). Folk and Jim are already built
# with -fno-omit-frame-pointer for this.
#
#   research/bench/flamegraph.sh NAME program.folk [folk-binary]
#
# Writes research/out/perf/NAME.svg (flame graph), NAME.folded (stacks)
# and NAME.top.txt (self time by function). Run from the repository root.
name=$1; program=$2; folk=${3:-./folk}
perf=${PERF:-/opt/ft/perf}
fg=${FLAMEGRAPH:-/opt/ft/FlameGraph}
out=research/out/perf
mkdir -p $out

$perf record -o /tmp/$name.perf.data --freq=997 -e cpu-clock --call-graph fp -g \
    -- $folk "$program" > /dev/null 2> /tmp/$name.perf.err
$perf script -i /tmp/$name.perf.data -f 2> /dev/null > /tmp/$name.perf.script
$fg/stackcollapse-perf.pl /tmp/$name.perf.script > $out/$name.folded 2> /dev/null
# --minwidth drops frames narrower than a pixel, which nobody can read
# and which make up most of the file.
$fg/flamegraph.pl --title "$name" --minwidth 1 $out/$name.folded > $out/$name.svg

# Self time by function: the leaf frame of every folded stack.
total=$(awk '{ n += $NF } END { print n }' $out/$name.folded)
awk -v total="$total" '{
        n = $NF; $NF = ""; split($0, frames, ";"); leaf = frames[length(frames)]
        sub(/ +$/, "", leaf); self[leaf] += n
    } END {
        for (f in self) printf "%6.2f%%  %8d  %s\n", 100 * self[f] / total, self[f], f
    }' $out/$name.folded | sort -rn | head -40 > $out/$name.top.txt
echo "$total samples; see $out/$name.svg and $out/$name.top.txt"
