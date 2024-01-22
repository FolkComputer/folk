source "lib/c.tcl"
source "trie.tcl"

set cc [c create]
$cc cflags -I. trie.c db.c
$cc include <stdlib.h>
$cc include "db.h"
$cc code { Db* db; }
$cc proc testRun {} void {
    db = dbNew();
    testAssert(db, clause("This", "is", "a", "thing", 0));
    testAssert(db, clause("This", "is", "a", "thing", 0));
    testAssert(db, clause("This", "is", "another", "thing", 0));
}
$cc proc testGetClauseToStatementIdTrie {} Trie* {
    return dbGetClauseToStatementId(db);
}
try {
    $cc compile
} on error e { puts stderr $e }

proc dbDotify {db} {
    set dot [list]
    dict for {id stmt} [all] {
        lappend dot "subgraph <cluster_$id> {"
        lappend dot "color=lightgray;"

        set label [statement clause $stmt]
        set label [join [lmap line [split $label "\n"] {
            expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
        }] "\n"]
        set label [string map {"\"" "\\\""} [string map {"\\" "\\\\"} $label]]
        lappend dot "<$id> \[label=\"$id: $label\"\];"

        dict for {matchId _} [statement parentMatchIds $stmt] {
            set parents [lmap edge [matchEdges $matchId] {expr {
                [dict get $edge type] == 1 ? "[dict get $edge statement]" : [continue]
            }}]
            lappend dot "<$matchId> \[label=\"$matchId <- $parents\"\];"
            lappend dot "<$matchId> -> <$id>;"
        }

        lappend dot "}"

        dict for {childMatchId _} [statement childMatchIds $stmt] {
            lappend dot "<$id> -> <$childMatchId>;"
        }
    }
    return "digraph { rankdir=LR; [join $dot "\n"] }"
}
proc dbWriteToPdf {db pdf} {
    exec dot -Tpdf <<[] >$pdf
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    testRun
    trieWriteToPdf [testGetClauseToStatementIdTrie] db.pdf; puts db.pdf
}
