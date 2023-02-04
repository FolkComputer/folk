source "lib/c.tcl"
source "lib/trie.tcl"

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
            ret.clause = clause;
            ret.n_edges = n_parents + n_children;
            assert(ret.n_edges < sizeof(ret.edges)/sizeof(ret.edges[0]));
            return ret;
        }
    }
}

namespace eval Statements {
    $cc include <stdbool.h>
    $cc code [csubst {
        typedef struct trie trie_t;

        statement_t statements[32768];
        uint16_t nextStatementIdx = 1;
        trie_t* statementClauseToId;

        match_t matches[32768];
        match_handle_t addMatch(size_t n_parents, statement_handle_t parents[]) {
            match_handle_t ret = nextStatementIdx++;

            match_t match;
            match.n_edges = n_parents;
            assert(match.n_edges < sizeof(match.edges)/sizeof(match.edges[0]));
            for (int i = 0; i < n_parents; i++) {
                match.edges[i] = (edge_to_statement_t) { .type = PARENT, .statement = parents[i] };
            }

            return ret;
        }
    }]
    $cc import ::ctrie::cc lookup as trieLookup
    $cc import ::ctrie::cc add as trieAdd
    $cc proc add {Tcl_Interp* interp
                  Tcl_Obj* clause
                  size_t n_parents match_handle_t parents[]} statement_handle_t {
        // Empty set of parents = an assertion

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
        }

        bool isNewStatement = (id == -1);
        if (isNewStatement) {
            id = nextStatementIdx++;
            assert(id < sizeof(statements)/sizeof(statements[0]));
            statements[id] = create(clause, n_parents, parents, 0, NULL);
            trieAdd(interp, &statementClauseToId, clause, id);

        } else {

        }
        // if new then react
    }
}

$cc compile
