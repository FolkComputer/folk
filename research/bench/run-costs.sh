#!/bin/sh
# Runs costs.folk several times for each number of helper fns and keeps the
# smallest time seen for every row, which is the least disturbed by other
# threads.
#
#   research/bench/run-costs.sh [folk-binary] [runs]
folk=${1:-./folk}; runs=${2:-5}
for fns in 0 10 40; do
    rm -f /tmp/folk-bench-costs.all
    for run in $(seq $runs); do
        rm -f /tmp/folk-bench-costs.txt
        BENCH_FNS=$fns timeout -s KILL 300 $folk research/bench/costs.folk > /dev/null 2>&1
        cat /tmp/folk-bench-costs.txt >> /tmp/folk-bench-costs.all 2> /dev/null
    done
    head -1 /tmp/folk-bench-costs.all
    grep ' us$' /tmp/folk-bench-costs.all | awk '{
            value = $(NF-1); $NF = ""; $(NF-1) = ""; sub(/ +$/, "")
            if (!($0 in best)) { order[++n] = $0; best[$0] = value }
            else if (value < best[$0]) best[$0] = value
        } END { for (i = 1; i <= n; i++) printf "  %-48s %8.1f us\n", order[i], best[order[i]] }'
done
