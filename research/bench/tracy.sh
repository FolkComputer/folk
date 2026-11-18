#!/bin/sh
# Captures one run of a Folk program with Tracy, headless, and exports the
# zone statistics as CSV. Uses the TRACY_ENABLE build of folk (see
# research/verify/build-variant.sh) and the capture and csvexport tools
# built from vendor/tracy (see research/setup.sh).
#
#   research/bench/tracy.sh NAME program.folk
#
# Writes research/out/perf/NAME.zones.csv (one line per zone: totals,
# counts, mean, min, max) and leaves the full trace in /tmp/NAME.tracy,
# which the Tracy profiler opens as usual.
name=$1; program=$2
folk=research/verify/build/tracy/folk
tools=${TRACY_TOOLS:-/opt/ft}
out=research/out/perf
mkdir -p $out
rm -f /tmp/$name.tracy

# The client waits for a profiler to connect before it starts recording,
# so start the capture first and let it wait for the program.
$tools/tracy-capture/tracy-capture -f -o /tmp/$name.tracy -a 127.0.0.1 > /tmp/$name.capture.log 2>&1 &
capture=$!
sleep 1
$folk "$program" > /dev/null 2>&1
wait $capture
$tools/tracy-csvexport/tracy-csvexport /tmp/$name.tracy > $out/$name.zones.csv
echo "$(($(wc -l < $out/$name.zones.csv) - 1)) zones; see $out/$name.zones.csv"
