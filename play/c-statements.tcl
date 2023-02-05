set cc [c create]

namespace eval statement {
    $cc include <string.h>
    $cc include <stdlib.h>
    $cc include <assert.h>

    # $cc struct statement_handle_t { uint16_t idx; uint16_t generation; }
    # $cc struct match_handle_t { uint16_t idx; uint16_t generation; }
    $cc typedef int statement_handle_t
    $cc typedef int match_handle_t

    $cc enum edge_type_t { PARENT, CHILD }

    $cc struct edge_to_statement_t {
        edge_type_t type;
        statement_handle_t statement;
    }
    $cc struct match_t {
        size_t n_edges;
        edge_to_statement_t edges[32];
    }

    $cc struct edge_to_match_t {
        edge_type_t type;
        match_handle_t match;
    }
    $cc struct statement_t {
        Tcl_Obj* clause;

        size_t n_edges;
        edge_to_match_t edges[32];
    }

    $cc code {
        statement_t create(Tcl_Obj* clause,
                           size_t n_parents, match_handle_t parents[],
                           size_t n_children, match_handle_t children[]) {
            statement_t ret = {0};
            ret.clause = clause; Tcl_IncrRefCount(clause);
            ret.n_edges = n_parents + n_children;
            assert(ret.n_edges < sizeof(ret.edges)/sizeof(ret.edges[0]));
            return ret;
        }
    }

    namespace export clause parentMatchIds childMatchIds
    proc clause {stmt} { dict get $stmt clause }
    proc parentMatchIds {stmt} { dict get $stmt edges }
    proc childMatchIds {stmt} { dict get $stmt edges }
    namespace ensemble create

    namespace export short
    proc short {stmt} {
        set lines [split [clause $stmt] "\n"]
        set line [lindex $lines 0]
        if {[string length $line] > 80} {set line "[string range $line 0 80]..."}
        dict with stmt { format "{%s} %s {%s}" $edges $line $edges }
    }
}

namespace eval Statements { ;# singleton Statement store
    $cc include <stdbool.h>
    $cc code [csubst {
        typedef struct trie trie_t;

        statement_t statements[32768];
        uint16_t nextStatementIdx = 1;
        trie_t* statementClauseToId;

        match_t matches[32768];
        uint16_t nextMatchIdx = 1;
    }]
    $cc import ::ctrie::cc create as trieCreate
    $cc import ::ctrie::cc lookup as trieLookup
    $cc import ::ctrie::cc add as trieAdd
    $cc import ::ctrie::cc scanVariable as scanVariable
    $cc proc init {} void {
        statementClauseToId = trieCreate();
    }

    $cc proc addMatchImpl {size_t n_parents statement_handle_t parents[]} match_handle_t {
        match_handle_t matchId = nextMatchIdx++;

        match_t match;
        match.n_edges = n_parents;
        assert(match.n_edges < sizeof(match.edges)/sizeof(match.edges[0]));
        for (int i = 0; i < n_parents; i++) {
            match.edges[i] = (edge_to_statement_t) { .type = PARENT, .statement = parents[i] };
        }

        return matchId;
    }
    proc addMatch {parentMatchIds} {
        addMatchImpl [llength $parentMatchIds] $parentMatchIds
    }

    $cc proc addImpl {Tcl_Interp* interp
                      Tcl_Obj* clause
                      size_t n_parents match_handle_t parents[]} Tcl_Obj* {
        // Is this clause already present among the existing statements?
        Tcl_Obj* ids = trieLookup(interp, statementClauseToId, clause);
        int idslen; Tcl_ListObjLength(interp, ids, &idslen);
        statement_handle_t id;
        if (idslen == 1) {
            Tcl_Obj* idobj; Tcl_ListObjIndex(interp, ids, 0, &idobj);
            id = Tcl_GetIntFromObj(interp, idobj, &id);

        } else if (idslen == 0) {
            id = -1;

        } else {
            // error WTF
            printf("WTF: looked up %s\n", Tcl_GetString(clause));
            exit(1);
        }

        bool isNewStatement = (id == -1);
        if (isNewStatement) {
            id = nextStatementIdx++;
            assert(id < sizeof(statements)/sizeof(statements[0]));
            statements[id] = create(clause, n_parents, parents, 0, NULL);
            trieAdd(interp, &statementClauseToId, clause, id);

        } else {
            for (size_t i = 0; i < n_parents; i++) {
                size_t edgeIdx = statements[id].n_edges++;
                assert(edgeIdx < sizeof(statements[id].edges)/sizeof(statements[id].edges[0]));
                statements[id].edges[edgeIdx].type = PARENT;
                statements[id].edges[edgeIdx].match = parents[i];
            }
        }

        for (size_t i = 0; i < n_parents; i++) {
            if (parents[i] == 0) { continue; } // ?

            match_t* match = &matches[parents[i]];
            size_t edgeIdx = match->n_edges++;
            assert(edgeIdx < sizeof(match->edges)/sizeof(match->edges[0]));
            match->edges[edgeIdx].type = CHILD;
            match->edges[edgeIdx].statement = id;
        }

        // return {id, isNewStatement};
        Tcl_Obj* ret[] = {Tcl_NewIntObj(id), Tcl_NewIntObj(isNewStatement)};
        return Tcl_NewListObj(sizeof(ret)/sizeof(ret[0]), ret);
    }
    proc add {clause {parents {{} true}}} {
        addImpl $clause [dict size $parents] [lmap parent [dict keys $parents] {
            expr {$parent eq {} ? 0 : $parent}
        }]
    }
    $cc proc exists {statement_handle_t id} int {
        return statements[id].clause != NULL;
    }
    $cc proc get {statement_handle_t id} statement_t {
        return statements[id];
    }
    $cc proc remove_ {statement_handle_t id} void {
        memset(&statements[id], 0, sizeof(statements[id]));
    }
    # $cc proc size {} size_t {}

    $cc proc unifyImpl {Tcl_Interp* interp Tcl_Obj* a Tcl_Obj* b} Tcl_Obj* {
        int alen; Tcl_Obj** awords;
        int blen; Tcl_Obj** bwords;
        Tcl_ListObjGetElements(interp, a, &alen, &awords);
        Tcl_ListObjGetElements(interp, b, &blen, &bwords);
        if (alen != blen) { return NULL; }

        Tcl_Obj* match = Tcl_NewDictObj();
        for (int i = 0; i < alen; i++) {
            char aVarName[100]; char bVarName[100];
            if (scanVariable(awords[i], aVarName, sizeof(aVarName))) {
                Tcl_DictObjPut(interp, match, Tcl_NewStringObj(aVarName, -1), bwords[i]);
            } else if (scanVariable(bwords[i], bVarName, sizeof(bVarName))) {
                Tcl_DictObjPut(interp, match, Tcl_NewStringObj(bVarName, -1), awords[i]);
            } else if (!(awords[i] == bwords[i] ||
                         strcmp(Tcl_GetString(awords[i]), Tcl_GetString(bwords[i])) == 0)) {
                return NULL;
            }
        }
        return match;
    }
    $cc proc unify {Tcl_Interp* interp Tcl_Obj* a Tcl_Obj* b} Tcl_Obj* {
        Tcl_Obj* ret = unifyImpl(interp, a, b);
        if (ret == NULL) return Tcl_NewStringObj("false", -1);
        return ret;
    }

    $cc proc findStatementsMatching {Tcl_Interp* interp Tcl_Obj* pattern} Tcl_Obj* {
        Tcl_Obj* idsobj = trieLookup(interp, statementClauseToId, pattern);
        int idslen; Tcl_Obj** ids;
        if (Tcl_ListObjGetElements(interp, idsobj, &idslen, &ids) != TCL_OK) { exit(1); }

        Tcl_Obj* matches[idslen]; int matchcount = 0;
        for (int i = 0; i < idslen; i++) {
            int id; Tcl_GetIntFromObj(interp, ids[i], &id);
            Tcl_Obj* match = unifyImpl(interp, pattern, statements[id].clause);
            if (match != NULL) {
                Tcl_DictObjPut(interp, match, Tcl_ObjPrintf("__matcheeId"), Tcl_NewIntObj(id));
                matches[matchcount++] = match;
            }
        }

        return Tcl_NewListObj(matchcount, matches);
    }

    $cc compile
    init        

    rename findStatementsMatching findMatches
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    puts [Statements::addImpl [list whatever dude] 0 [list]]
    puts [Statements::addImpl [list cool dude] 0 [list]]
    puts [Statements::addMatch 2 [list 1 2]]
    puts "matches: [Statements::findStatementsMatching [list /response/ dude]]"
}
