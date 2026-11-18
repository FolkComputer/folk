#!/bin/sh
# Runs the pipeline benchmark several times per configuration and prints
# every run, because the number of worker threads varies from run to run
# and moves the result.
#
#   research/bench/run-pipeline.sh FOLK-BINARY RUNS "FNS BLOCKED" ...
folk=$1; runs=$2; shift 2
for config in "$@"; do
    set -- $config
    for run in $(seq $runs); do
        rm -f /tmp/folk-bench-pipeline.txt
        BENCH_FNS=$1 BENCH_BLOCKED=$2 BENCH_TICKS=${BENCH_TICKS:-5000} \
            timeout -s KILL 300 $folk research/bench/pipeline.folk > /dev/null 2>&1
        cat /tmp/folk-bench-pipeline.txt 2> /dev/null || echo "fns=$1 blocked=$2 FAILED"
    done
done
