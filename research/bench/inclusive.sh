#!/bin/sh
# Inclusive time of chosen functions in a folded profile: the share of
# samples that have the function anywhere on the stack.
#
#   research/bench/inclusive.sh research/out/perf/NAME.folded [function ...]
#
# With no functions given, prints the ones that explain the evaluator.
folded=$1; shift
[ $# -eq 0 ] && set -- workerLoop workerRun runWhenBlock runBlock Jim_EvalObj \
    SayWithSourceFunc HoldStatementGloballyFunc reactToNewStatement \
    dbInsertOrReuseStatement dbInsertMatch dbQuery trieAdd trieLookup trieRemove \
    statementRemoveSelf matchRemoveSelf pushRunWhenBlock clauseUnify \
    JimSetScriptFromAny SetListFromAny.isra.0 JimMakeListStringRep SetDictFromAny \
    Jim_DictMerge JimDictMergeCommand malloc cfree@GLIBC_2.2.5 \
    workerSteal workQueueTake globalWorkQueueTake __sched_yield \
    blockStatsUpdate epochEnd epochGlobalCollect sysmon
awk -v want="$*" '
    BEGIN { n = split(want, names, " "); for (i = 1; i <= n; i++) wanted[names[i]] = 1 }
    {
        w = $NF; $NF = ""; total += w
        m = split($0, frames, ";")
        delete seen
        for (i = 1; i <= m; i++) {
            f = frames[i]; sub(/ +$/, "", f)
            if ((f in wanted) && !(f in seen)) { seen[f] = 1; incl[f] += w }
        }
    }
    END {
        for (i = 1; i <= n; i++) printf "%6.2f%%  %s\n", 100 * incl[names[i]] / total, names[i]
    }' "$folded"
