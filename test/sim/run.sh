#!/bin/bash
# Run the headless simulation tests (see README.md).
#
#   test/sim/run.sh [--quick]     --quick: Folk-level tests and the end-to-end test only
#
# Environment: SIM_OUT (where logs, frames and captures go; default a new
# directory under /tmp), FUZZ_SEED (default 1).
set -u
cd "$(dirname "$0")/../.."
quick=0; [ "${1:-}" = "--quick" ] && quick=1
out=${SIM_OUT:-$(mktemp -d /tmp/folk-sim.XXXXXX)}
mkdir -p "$out"
seed=${FUZZ_SEED:-1}
failed=()

run() {    # run <name> <timeout seconds> <command...>
    local name=$1 secs=$2; shift 2
    local t0=$(date +%s)
    timeout -k 10 "$secs" "$@" > "$out/$name.log" 2>&1
    local rc=$? secsTaken=$(( $(date +%s) - t0 ))
    if [ $rc = 0 ]; then
        printf 'ok    %-18s %4d s\n' "$name" $secsTaken
    else
        printf 'FAIL  %-18s %4d s   (exit %d; see %s)\n' "$name" $secsTaken $rc "$out/$name.log"
        failed+=("$name")
    fi
}

[ -x ./folk ] || { echo "build Folk first: make deps && make" >&2; exit 2; }
make -s -C test/sim/hidemu || exit 2
echo "logs and artifacts in $out"

# Folk-level tests: one Folk each, no external driver.
for t in headless-display keyboard-seq mouse sim-table browser; do
    run "$t" 240 env TERM=dumb ./folk "test/$t.folk"
done
# The real on-table editor on a virtual page, typed into with the emulated keyboard.
run editor 300 env SIM_OUT="$out/editor" test/sim/tests/editor.sh
# The harness itself.
run folksim 300 python3 test/sim/folksim.py --selftest
if [ $quick = 0 ]; then
    run audio 300 test/sim/audio/selftest.sh
    # The test apps through Playwright (the reference the fuzzer compares with).
    run apps-reference 300 node test/sim/tests/apps_reference.mjs --out "$out/reference"
fi
# Type the browser wish into the editor, then use six GUI apps with USB keyboard and mouse.
run e2e-browser 600 python3 test/sim/tests/e2e_browser.py --out "$out/e2e"
if [ $quick = 0 ]; then
    run fuzz-browser 1200 python3 test/sim/tests/fuzz_browser.py --seed "$seed" \
        --structured 5 --monkey 2 --audio 1 --out "$out/fuzz"
fi

if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "all passed"
