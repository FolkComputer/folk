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

set cc [C]
$cc cflags -I. trie.c db.c
$cc include <stdlib.h>
$cc include <assert.h>
$cc include "db.h"
$cc import $trieCc jimObjToClause as jimObjToClause
$cc import $trieCc clauseToJimObj as clauseToJimObj
$cc proc testNew {} Db* { return dbNew(); }
$cc proc testAssert {Db* db Jim_Obj* clauseObj} Statement* {
    Clause* c = jimObjToClause(clauseObj);
    Statement* ret = dbAssert(db, c);
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

namespace eval statement {
    upvar cc cc
    $cc code {
typedef struct {
    EdgeType type;
    void* to;
} EdgeTo;
typedef struct ListOfEdgeTo {
    size_t capacityEdges;
    size_t nEdges; // This is an estimate.
    EdgeTo edges[];
} ListOfEdgeTo;
typedef struct Statement {
    Clause* clause;

    // List of edges to parent & child Matches:
    ListOfEdgeTo* edges; // Allocated separately so it can be resized.
} Statement;
    }
    $cc proc clause {Statement* stmt} Jim_Obj* {
        return clauseToJimObj(statementClause(stmt));
    }
    $cc proc parentMatches {Statement* stmt} Jim_Obj* {
        int nParents = 0;
        Jim_Obj* parentObjs[stmt->edges->nEdges];
        for (int i = 0; i < stmt->edges->nEdges; i++) {
            if (stmt->edges->edges[i].type == EDGE_PARENT) {
                parentObjs[nParents++] = Jim_ObjPrintf("(Match*) %p", stmt->edges->edges[i].to);
            }
        }
        return Jim_NewListObj(interp, parentObjs, nParents);
    }
    $cc proc childMatches {Statement* stmt} Jim_Obj* {
        int nChildren = 0;
        Jim_Obj* childObjs[stmt->edges->nEdges];
        for (int i = 0; i < stmt->edges->nEdges; i++) {
            if (stmt->edges->edges[i].type == EDGE_CHILD) {
                childObjs[nChildren++] = Jim_ObjPrintf("(Match*) %p", stmt->edges->edges[i].to);
            }
        }
        return Jim_NewListObj(interp, childObjs, nChildren);
    }
    foreach fn {clause parentMatches childMatches} {
        proc $fn {args} [subst {::$fn {*}\$args}]
    }
    namespace ensemble create
}
try {
    $cc compile
} on error e { puts stderr [errorInfo $e [info stacktrace]] }

proc dbDotify {db} {
    set dot [list]
    foreach stmt [testQuery $db /...anything/] {
        set label [statement clause $stmt]
        set label [join [lmap line [split $label "\n"] {
            expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
        }] "\n"]
        set label [string map {"\"" "\\\""} [string map {"\\" "\\\\"} $label]]
        lappend dot "<$stmt> \[label=\"$stmt: $label\"\];"

        foreach matchId [statement parentMatches $stmt] {
            # set parents [lmap edge [matchEdges $matchId] {expr {
            #     [dict get $edge type] == 1 ? "[dict get $edge statement]" : [continue]
            # }}]
            # lappend dot "<$matchId> \[label=\"$matchId <- $parents\"\];"
            lappend dot "<$matchId> -> <$stmt>;"
        }

        foreach childMatchId [statement childMatches $stmt] {
            lappend dot "<$stmt> -> <$childMatchId>;"
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
    dbWriteToPdf $db db.pdf; puts db.pdf
}
