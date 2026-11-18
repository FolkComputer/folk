#!/bin/sh
# Runs every benchmark and writes the tables under research/out/perf.
# Takes about five minutes. Needs the tools from research/setup.sh and,
# for the comparison columns, the what-if build:
#   research/bench/build-whatif.sh idle-backoff
#
#   research/bench/run-all.sh        # from the repository root
out=research/out/perf
perf=${PERF:-/opt/ft/perf}
whatif=research/verify/build/whatif-idle-backoff/folk
mkdir -p $out

{
    for build in ./folk $whatif; do
        [ -x $build ] || continue
        echo "== $build"
        $perf stat -e task-clock,context-switches $build research/bench/idle.folk 2>&1 |
            grep -E 'task-clock|context-switches|elapsed'
        tail -1 /tmp/folk-bench-idle.txt
    done
} > $out/idle.txt

{
    for build in ./folk $whatif; do
        [ -x $build ] || continue
        echo "== $build"
        BENCH_LATENCY=1 BENCH_TICKS=10000 research/bench/run-pipeline.sh $build 3 \
            "0 0" "10 0" "40 0" "0 1" "0 3"
    done
} > $out/pipeline.txt

timeout -s KILL 300 ./folk research/bench/trie-width.folk > /dev/null 2>&1
cp /tmp/folk-bench-trie.txt $out/trie-width.txt

research/bench/run-costs.sh ./folk 5 > $out/costs.txt
echo "tables are in $out"
