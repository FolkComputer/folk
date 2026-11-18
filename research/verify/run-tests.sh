#!/bin/sh
# Runs Folk test programs under one build of folk and collects what the
# sanitizers print.
#
#   research/verify/run-tests.sh NAME [test.folk ...]
#
# NAME is `plain` for ./folk, or a variant built by build-variant.sh.
# Reports land in research/verify/build/NAME/reports/. Run from the root.
name=$1; shift
if [ "$name" = plain ]; then folk=./folk; else folk=research/verify/build/$name/folk; fi
reports=research/verify/build/$name/reports
rm -rf "$reports"; mkdir -p "$reports"
[ $# -eq 0 ] && set -- test/*.folk

export TSAN_OPTIONS="halt_on_error=0 second_deadlock_stack=1 history_size=5 exitcode=0"
export ASAN_OPTIONS="detect_leaks=0 halt_on_error=0 exitcode=0 detect_stack_use_after_return=1"
export UBSAN_OPTIONS="print_stacktrace=1 halt_on_error=0"

for t in "$@"; do
    base=$(basename "$t" .folk)
    start=$(date +%s.%N)
    # Folk redirects each program's output to /var/tmp/folk-PID/. Have the
    # shell report its pid and then become folk, so we know which one.
    timeout -s KILL ${TEST_TIMEOUT:-120} sh -c 'echo $$ > "$1"; exec "$2" "$3"' _ \
        "$reports/$base.pid" "$folk" "$t" > "$reports/$base.out" 2> "$reports/$base.err"
    code=$?
    end=$(date +%s.%N)
    d=/var/tmp/folk-$(cat "$reports/$base.pid")
    if [ -d "$d" ]; then
        mkdir -p "$reports/$base.d"
        cp "$d"/* "$reports/$base.d/" 2>/dev/null
        rm -rf "$d"
    fi
    rm -f "$reports/$base.pid"
    # Sanitizer output goes to whichever stderr is current, so look in the
    # per-program files as well.
    warnings=$(cat "$reports/$base.err" "$reports/$base.d"/* 2>/dev/null |
        grep -c 'WARNING: ThreadSanitizer\|ERROR: AddressSanitizer\|runtime error:')
    printf '%-24s exit=%-3s %5.1fs  sanitizer-reports=%s\n' "$base" "$code" \
        "$(echo "$end - $start" | bc)" "$warnings"
done
