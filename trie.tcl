source "lib/c.tcl"

set cc [c create]
$cc cflags -I. trie.c
$cc include <stdlib.h>
$cc include "trie.h"
$cc proc tclify {Trie* trie} Tcl_Obj* {
    int objc = 3 + trie->nbranches;
    Tcl_Obj* objv[objc];
    objv[0] = Tcl_ObjPrintf("x%" PRIxPTR, (uintptr_t) trie);
    objv[1] = trie->key ? Tcl_ObjPrintf("%s", trie->key) : Tcl_ObjPrintf("ROOT");
    objv[2] = trie->value ? Tcl_ObjPrintf("%"PRIu64, trie->value) : Tcl_ObjPrintf("NULL");
    for (int i = 0; i < trie->nbranches; i++) {
        objv[3+i] = trie->branches[i] ? tclify(trie->branches[i]) : Tcl_NewStringObj("", 0);
    }
    return Tcl_NewListObj(objc, objv);
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
$cc proc test {} Tcl_Obj* {
    Trie* t = trieCreate();
    trieAdd(t, clause("This", "is", "a", "thing", 0), 1);
    trieAdd(t, clause("This", "is", "another", "thing", 0), 2);
    trieAdd(t, clause("This", "is", "another", "statement", 0), 300);
    return tclify(t);
}
$cc compile

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

set trie [test]; puts $trie
exec dot -Tpdf <<[dotify $trie] >trie.pdf
puts trie.pdf
