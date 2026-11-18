#!/bin/sh
# Runs every reproducer and prints what it observed.
#
#   research/repro/run.sh            # from the repository root
#
# Each program states what was expected and what was seen in its header.
# Two of them only show their defect under the ASan build
# (research/verify/build-variant.sh asan ...); they are run with it when
# it exists.
asan=research/verify/build/asan/folk
export ASAN_OPTIONS="detect_leaks=0 halt_on_error=0 exitcode=0"
export UBSAN_OPTIONS="print_stacktrace=0"

for program in research/repro/*.folk; do
    name=$(basename "$program" .folk)
    folk=./folk
    case $name in
        long-variable-name|kill-diagnostic) [ -x $asan ] && folk=$asan ;;
    esac
    rm -f /tmp/folk-repro-*.txt
    before=$(ls -d /var/tmp/folk-* 2>/dev/null)
    timeout -s KILL 60 $folk "$program" > /tmp/folk-repro.out 2> /tmp/folk-repro.err
    status=$?
    echo "== $name  ($folk, exit status $status)"
    cat /tmp/folk-repro-*.txt 2>/dev/null | sed 's/^/   /'
    # Sanitizer reports land in the per-program stderr files.
    for d in /var/tmp/folk-*; do
        echo "$before" | grep -qx "$d" && continue
        cat "$d"/*.stderr /tmp/folk-repro.err 2>/dev/null |
            grep 'ERROR: AddressSanitizer\|SUMMARY: AddressSanitizer\|dbQuery: Too many\|Fatal (uncaught)' |
            sort -u | sed 's/==[0-9]*==//; s/^/   /'
        rm -rf "$d"
    done
done
