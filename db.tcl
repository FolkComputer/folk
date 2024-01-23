source "lib/c.tcl"
proc assert condition {
    set s "{$condition}"
    if {![uplevel 1 expr $s]} {
        set errmsg "assertion failed: $condition"
        try {
            if {[lindex $condition 1] eq "eq" && [string index [lindex $condition 0] 0] eq "$"} {
                set errmsg "$errmsg\n[uplevel 1 [list set [string range [lindex $condition 0] 1 end]]] is not equal to [lindex $condition 2]"
            }
        } on error e {}
        return -code error $errmsg
    }
}
source "trie.tcl"
set trieCc $cc

set cc [c create]
$cc cflags -I. trie.c db.c
$cc include <stdlib.h>
$cc include <assert.h>
$cc include "db.h"
$cc import $trieCc jimObjToClause as jimObjToClause
$cc proc testNew {} Db* { return dbNew(); }
$cc proc testAssert {Db* db Jim_Obj* clauseObj} Statement* {
    Clause* c = jimObjToClause(clauseObj);
    Statement* ret = dbAssert(db, c);
    free(c);
    return ret;
}
$cc proc testQuery {Db* db Jim_Obj* patternObj} Jim_Obj* {
    Clause* c = jimObjToClause(patternObj);
    ResultSet* rs = dbQuery(db, c);
    free(c);

    int nResults = (int) rs->nResults;
    Jim_Obj* resultObjs[nResults];
    for (size_t i = 0; i < rs->nResults; i++) {
        Statement* result = rs->results[i];
        resultObjs[i] = Jim_ObjPrintf("(Statement*) 0x%" PRIxPTR, (uintptr_t) result);
    }
    free(rs);
    return Jim_NewListObj(interp, resultObjs, nResults);
}
$cc proc testGetClauseToStatementIdTrie {Db* db} Trie* {
    return dbGetClauseToStatementId(db);
}
try {
    $cc compile
} on error e { puts stderr $e }

proc dbDotify {db} {
    puts ([testQuery $db /...anything/])
    set dot [list]
    dict for {id stmt} [testQuery $db /...anything/] {
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
    exec dot -Tpdf <<[dbDotify $db] >$pdf
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    set db [testNew]
    proc Test: {args} {
        upvar db db
        set clause $args
        set stmt [testAssert $db $clause]
        assert {[list $stmt] eq [testQuery $db $clause]}
        return $stmt
    }
    Test: This is a thing
    Test: This is another thing
    Test: Also x is true besides
    assert {[llength [testQuery $db [list This is /some/ thing]]] == 2}

    trieWriteToPdf [testGetClauseToStatementIdTrie $db] trie.pdf; puts trie.pdf
    dbWriteToPdf [dbDotify $db] db.pdf; puts db.pdf
}
