source "lib/c.tcl"
source "lib/trie.tcl"

set cc [c create]

puts $::ctrie::lookupImpl_import

namespace eval statement {
    $cc include <string.h>
    $cc include <stdlib.h>
    $cc include <assert.h>

    $cc struct statement_handle_t { uint16_t idx; uint16_t generation; }
    $cc struct match_handle_t { uint16_t idx; uint16_t generation; }

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
        statement_t createImpl(Tcl_Obj* clause,
                               size_t n_parents, match_handle_t parents[],
                               size_t n_children, match_handle_t children[]) {
            statement_t ret = {0};
            ret.n_edges = n_parents + n_children;
            assert(ret.n_edges < sizeof(ret.edges)/sizeof(ret.edges[0]));
            return ret;
        }
    }
}

namespace eval Statements {
    $cc code {
        typedef struct trie trie_t;

        statement_t statements[32768];
        uint16_t nextStatementIdx = 1;
        trie_t* statementClauseToId;

        match_t matches[32768];
        match_handle_t addMatch(size_t n_parents, statement_handle_t parents[]) {
            match_handle_t ret;
            ret.idx = nextStatementIdx++;

            match_t match;
            match.n_edges = n_parents;
            assert(match.n_edges < sizeof(match.edges)/sizeof(match.edges[0]));
            for (int i = 0; i < n_parents; i++) {
                match.edges[i] = (edge_to_statement_t) { .type = PARENT, .statement = parents[i] };
            }

            return ret;
        }
    }
    $cc proc add {Tcl_Interp* interp
                  Tcl_Obj* clause
                  size_t n_parents match_handle_t parents[]} statement_handle_t {
        // Empty set of parents = an assertion

        // Is this clause already present among the existing statements?
        Tcl_Obj* ids = lookup(interp, statementClauseToId, clause);
        int idslen; Tcl_ListObjLength(interp, ids, &idsLen);
        if (idslen == 1) {
            Tcl_Obj* idobj; Tcl_ListObjIndex(interp, ids, 0, &idobj);
            int id; Tcl_GetIntFromObj(interp, idobj, &id);

            statements[id].setsOfParents[newSetOfParentsId] = parents;

            return { .id = id, .parentSet = parents };

        } else if (idslen == 0) {
            int id = nextStatementId++;
            statement_t stmt = create(clause, 1, parents, 0, NULL);
            statements[id] = stmt;

            int objc; Tcl_Obj** objv; Tcl_ListObjGetElements(interp, clause, &objc, &objv);
            trieAddImpl(&statementClauseToId, objc, objv, id);

            return { .id = id, .parentSet = parents };

        } else {
            // error WTF
        }
                      
        // if new then react
    }
}

$cc compile
source "lib/c.tcl"

set cc [c create]

namespace eval statement {
    $cc include <string.h>
    $cc include <stdlib.h>

    $cc typedef uint32_t statement_id_t
    $cc typedef {struct trie} trie_t
    $cc struct parent_set_t {
        statement_id_t parent[2];
    }
    $cc struct child_t {
        statement_id_t id;
        parent_set_t parentSet;
    }
    $cc struct statement_t {
        Tcl_Obj* clause;
        parent_set_t setsOfParents[8];

        size_t nchildren;
        child_t children[];
    }

    $cc proc createImpl {Tcl_Obj* clause
                         size_t nsetsOfParents parent_set_t[8] setsOfParents} statement_t* {
        size_t size = sizeof(statement_t) + 10*sizeof(child_t);
        statement_t* ret = ckalloc(size); memset(ret, 0, size);

        ret->clause = clause; Tcl_IncrRefCount(ret->clause);

        if (nsetsOfParents > 8) { exit(1); }
        memcpy(ret->setsOfParents, setsOfParents, nsetsOfParents*sizeof(parent_set_t));

        ret->nchildren = 10;

        return ret;
    }
}

namespace eval Statements {
    $cc code {
        size_t nstatements;
        statement_t* statements[32768];
        statement_id_t nextStatementId = 1;
        trie_t* statementClauseToId;
    }
    $cc proc add {Tcl_Interp* interp
                  Tcl_Obj* clause parent_set_t parents} child_t {
        // Empty set of parents = an assertion

        // Is this clause already present among the existing statements?
        Tcl_Obj* ids = lookup(interp, statementClauseToId, clause);
        int idslen; Tcl_ListObjLength(interp, ids, &idsLen);
        if (idslen == 1) {
            Tcl_Obj* idobj; Tcl_ListObjIndex(interp, ids, 0, &idobj);
            int id; Tcl_GetIntFromObj(interp, idobj, &id);

            statements[id].setsOfParents[newSetOfParentsId] = parents;

            return { .id = id, .parentSet = parents };

        } else if (idslen == 0) {
            int id = nextStatementId++;
            statement_t stmt = create(clause, 1, parents, 0, NULL);
            statements[id] = stmt;

            int objc; Tcl_Obj** objv; Tcl_ListObjGetElements(interp, clause, &objc, &objv);
            trieAddImpl(&statementClauseToId, objc, objv, id);

            return { .id = id, .parentSet = parents };

        } else {
            // error WTF
        }
    }
}

$cc compile
