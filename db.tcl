source "lib/c.tcl"
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
# TODO: Return list of Statement*.
$cc proc testQuery {Db* db Jim_Obj* patternObj} Statement* {
    Clause* c = jimObjToClause(patternObj);
    ResultSet* rs = dbQuery(db, c);
    free(c);
    assert(rs->nResults == 1);
    Statement* ret = rs->results[0];
    free(rs);
    return ret;
}
$cc proc testGetClauseToStatementIdTrie {Db* db} Trie* {
    return dbGetClauseToStatementId(db);
}
try {
    $cc compile
} on error e { puts stderr $e }

proc dbDotify {db} {
    set dot [list]
    dict for {id stmt} [testQuery ...] {
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
        puts "$stmt ([testQuery $db $clause])"
    }
    Test: This is a thing
    Test: This is another thing
    Test: Also x is true besides
    trieWriteToPdf [testGetClauseToStatementIdTrie $db] trie.pdf; puts trie.pdf
    dbWriteToPdf [dbDotify $db] db.pdf; puts db.pdf
}
