source "lib/c.tcl"

set cc [c create]
$cc cflags -I. trie.c
$cc include <stdlib.h>
$cc include "trie.h"
$cc proc trieTclify {Trie* trie} Jim_Obj* {
    int objc = 3 + trie->nbranches;
    Jim_Obj* objv[objc];
    objv[0] = Jim_ObjPrintf("x%" PRIxPTR, (uintptr_t) trie);
    objv[1] = trie->key ? Jim_ObjPrintf("%s", trie->key) : Jim_ObjPrintf("ROOT");
    objv[2] = trie->value ? Jim_ObjPrintf("%"PRIu64, trie->value) : Jim_ObjPrintf("NULL");
    for (int i = 0; i < trie->nbranches; i++) {
        objv[3+i] = trie->branches[i] ? trieTclify(trie->branches[i]) : Jim_NewStringObj(interp, "", 0);
    }
    return Jim_NewListObj(interp, objv, objc);
}
$cc proc lookup {Trie* trie Jim_Obj* patternObj} Jim_Obj* {
    int nterms = Jim_ListLength(interp, patternObj);
    Clause* pattern = alloca(SIZEOF_CLAUSE(nterms));
    pattern->nterms = nterms;
    for (int i = 0; i < nterms; i++) {
        Jim_Obj* termObj = Jim_ListGetIndex(interp, patternObj, i);
        pattern->terms[i] = Jim_GetString(termObj, NULL);
    }

    uint64_t results[50];
    int resultCount = trieLookup(trie, pattern, results, 50);

    Jim_Obj* resultObjs[resultCount];
    for (int i = 0; i < resultCount; i++) {
        resultObjs[i] = Jim_NewIntObj(interp, results[i]);
    }

    return Jim_NewListObj(interp, resultObjs, resultCount);
}
$cc code {
    Clause* clause(char* first, ...) {
        Clause* c = calloc(sizeof(Clause) + sizeof(char*)*100, 1);
        va_list argp;
        va_start(argp, first);
        c->terms[0] = first;
        int i = 1;
        for (;;) {
            if (i >= 100) abort();
            c->terms[i] = va_arg(argp, char*);
            if (c->terms[i] == 0) break;
            i++;
        }
        va_end(argp);
        c->nterms = i;
        return c;
    }
}
proc dotify {trie} {
    proc idify {word} {
        # generate id-able word by eliminating all non-alphanumeric
        regsub -all {\W+} $word "_"
    }
    proc labelify {word} {
        # shorten the longest lines
        set word [join [lmap line [split $word "\n"] {
            expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
        }] "\n"]
        string map {"\"" "\\\""} [string map {"\\" "\\\\"} $word]
    }
    proc subdot {subtrie} {
        set branches [lassign $subtrie ptr key id]

        set dot [list]
        lappend dot "$ptr \[label=\"[labelify $key]\"\];"
        foreach branch $branches {
            if {$branch eq {}} continue
            set branchptr [lindex $branch 0]
            lappend dot "$ptr -> $branchptr;"
            lappend dot [subdot $branch]
        }
        return [join $dot "\n"]
    }
    return "digraph { rankdir=LR; [subdot $trie] }"
}
$cc proc trieTest {} Trie* {
    Trie* t = trieCreate();
    t = trieAdd(t, clause("This", "is", "a", "thing", 0), 1);
    t = trieAdd(t, clause("This", "is", "another", "thing", 0), 2);
    t = trieAdd(t, clause("This", "is", "another", "statement", 0), 300);
    return t;
}
$cc compile

proc trieWriteToPdf {trie pdf} {
    exec dot -Tpdf <<[dotify [trieTclify $trie]] >$pdf
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    set trie [trieTest]; puts $trie

    puts [lookup $trie [list This is a thing]]
    puts [lookup $trie [list This is another thing]]
    puts [lookup $trie [list This is another statement]]
    puts [lookup $trie [list This is another /x/]]

    trieWriteToPdf $trie trie.pdf
    puts trie.pdf
}
