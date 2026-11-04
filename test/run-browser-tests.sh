#!/bin/bash
# Runs every test/browser-*.folk and, after each one has exited, checks
# that it left nothing behind: no /tmp/folk-browser* files and no
# Chromium / Python / uv processes that were started by that Folk.
#
#   test/run-browser-tests.sh            # once
#   test/run-browser-tests.sh 10         # 10 rounds (flakiness check)
#   TESTS="browser-e2e" test/run-browser-tests.sh
#
# Exits non-zero if any test fails or leaves anything behind.

cd "$(dirname "$0")/.."
rounds=${1:-1}
tests=${TESTS:-$(ls test/browser-*.folk | xargs -n1 basename | sed 's/\.folk$//')}
timeout_s=${TIMEOUT:-200}
status=0

leftover_processes() {
    # Every process started by this Folk inherits FOLK_BROWSER_TEST_TAG
    # in its environment; look for survivors.
    local tag=$1 found=""
    for envf in /proc/[0-9]*/environ; do
        if { cat "$envf" 2>/dev/null || true; } | tr '\0' '\n' | grep -qx "FOLK_BROWSER_TEST_TAG=$tag"; then
            local pid=${envf#/proc/}; pid=${pid%/environ}
            [ "$pid" = "$$" ] && continue
            found="$found $pid($(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null | cut -c1-60))"
        fi
    done
    echo "$found"
}

for round in $(seq 1 "$rounds"); do
    for t in $tests; do
        tag="folktest-$$-$round-$RANDOM"
        start=$(date +%s)
        FOLK_BROWSER_TEST_TAG=$tag timeout "$timeout_s" ./folk "test/$t.folk" > "/tmp/folk-test-$t.log" 2>&1
        rc=$?
        took=$(( $(date +%s) - start ))

        # Give the Uvx watchdog (polls once a second) a moment to notice.
        for i in 1 2 3 4 5 6; do
            left=$(leftover_processes "$tag")
            [ -z "$left" ] && break
            sleep 1
        done
        if [ -n "$left" ]; then
            echo "LEFTOVER PROCESSES after $t:$left"
            # Don't let them pile up across rounds.
            for p in $left; do kill -9 "${p%%(*}" 2>/dev/null; done
            rc=98
        fi
        if ls -d /tmp/folk-browser* >/dev/null 2>&1; then
            echo "LEFTOVER FILES after $t: $(ls -d /tmp/folk-browser*)"
            rm -rf /tmp/folk-browser*
            rc=99
        fi

        if [ $rc -eq 0 ]; then
            echo "round $round: $t ✅ (${took}s)"
        else
            echo "round $round: $t ❌ rc=$rc (${took}s)"
            tail -20 "/tmp/folk-test-$t.log"
            status=1
        fi
    done
done
exit $status
