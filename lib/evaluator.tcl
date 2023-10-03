# evaluator.tcl --
#
#     Implements the statement and match datatypes, the singleton
#     reactive/graph database of statements and matches, and the core
#     log-reducing evaluator for Folk.
#

namespace eval statement {
    # A statement contains a clause (a Tcl list which is the actual
    # 'words'/terms that constitute the statement, like [list the time
    # is 3:00]) and a resizable list of edges, which are handles of
    # matches (which are the parents and children of the statement).

    # A match contains a resizable list of edges, which are handles of
    # statements (which are the parents and children of the match).

    variable cc [c create]
    namespace export $cc

    $cc include <string.h>
    $cc include <stdlib.h>
    $cc include <assert.h>

    # Rather than being heap-allocated, statements and matches are
    # allocated out of memory pools (later in this file) that have a
    # generational indexing scheme.
    #
    # Therefore, instead of pointing to a statement or match with a
    # raw pointer, you point to these objects with handles that
    # consist of a slot index and a slot generation.
    $cc code {
        typedef struct statement_handle_t { int32_t idx; int32_t gen; } statement_handle_t;
        typedef struct match_handle_t { int32_t idx; int32_t gen; } match_handle_t;
    }
    $cc rtype statement_handle_t { $robj = Tcl_ObjPrintf("s%d:%d", $rvalue.idx, $rvalue.gen); }
    $cc argtype statement_handle_t { statement_handle_t $argname; sscanf(Tcl_GetString($obj), "s%d:%d", &$argname.idx, &$argname.gen); }
    $cc rtype match_handle_t { $robj = Tcl_ObjPrintf("m%d:%d", $rvalue.idx, $rvalue.gen); }
    $cc argtype match_handle_t { match_handle_t $argname; sscanf(Tcl_GetString($obj), "m%d:%d", &$argname.idx, &$argname.gen); }

    $cc enum edge_type_t { EMPTY, PARENT, CHILD }

    $cc struct edge_to_statement_t {
        edge_type_t type;
        statement_handle_t statement;
    }
    $cc code {
        typedef struct match_destructor_t {
            Tcl_Obj* body;
            Tcl_Obj* env;
        } match_destructor_t;
    }
    $cc rtype match_destructor_t {
        $robj = Tcl_ObjPrintf("DESTRUCTOR");
    }
    $cc argtype match_destructor_t {
        match_destructor_t $argname;
    }
    $cc struct match_t {
        int32_t gen;
        bool alive;

        bool isFromCollect;
        statement_handle_t collectId;

        match_destructor_t destructors[8];

        size_t capacity_edges;
        size_t n_edges; // This is an estimate.
        edge_to_statement_t* edges; // Allocated separately so it can be resized.
    }

    $cc struct edge_to_match_t {
        edge_type_t type;
        match_handle_t match;
    }
    $cc struct statement_t {
        int32_t gen;

        Tcl_Obj* clause;
        bool collectNeedsRecollect; // Dirty flag

        size_t capacity_edges;
        size_t n_edges; // This is an estimate.
        edge_to_match_t* edges; // Allocated separately so it can be resized.
    }

    $cc include <stdbool.h>
    $cc code {
        // Creates a new statement struct (that the caller will
        // probably want to put into the statement DB).
        statement_t statementCreate(Tcl_Obj* clause,
                                    size_t n_parents, match_handle_t parents[],
                                    size_t n_children, match_handle_t children[]) {
            statement_t ret;
            ret.clause = clause; Tcl_IncrRefCount(clause);
            ret.capacity_edges = (n_parents + n_children) * 2;
            if (ret.capacity_edges < 8) { ret.capacity_edges = 8; }
            // FIXME: Use edge helpers.
            ret.n_edges = 0;
            ret.edges = (edge_to_match_t *)ckalloc(sizeof(edge_to_match_t) * ret.capacity_edges);
            for (size_t i = 0; i < n_parents; i++) {
                ret.edges[ret.n_edges++] = (edge_to_match_t) { .type = PARENT, .match = parents[i] };
            }
            for (size_t i = 0; i < n_children; i++) {
                ret.edges[ret.n_edges++] = (edge_to_match_t) { .type = CHILD, .match = children[i] };
            }
            return ret;
        }
        bool matchHandleIsEqual(match_handle_t a, match_handle_t b) {
            return a.idx == b.idx && a.gen == b.gen;
        }
        bool statementHandleIsEqual(statement_handle_t a, statement_handle_t b) {
            return a.idx == b.idx && a.gen == b.gen;
        }

        static edge_to_match_t* statementEdgeAt(statement_t* stmt, size_t i) {
            assert(i < stmt->n_edges);
            assert(stmt->n_edges <= stmt->capacity_edges);
            assert(i < stmt->capacity_edges);
            return &stmt->edges[i];
        }
        // Given stmt, moves all non-EMPTY edges to the front of the
        // statement's edgelist, then updates stmt->n_edges
        // accordingly.
        //
        // Defragmentation is necessary to prevent continual growth of
        // the statement edgelist if you keep adding and removing
        // edges on the same statement.
        static void statementDefragmentEdges(statement_t* stmt) {
            // Copy all non-EMPTY edges into a new edgelist.
            size_t n_edges = 0;
            edge_to_match_t* edges = (edge_to_match_t *)ckalloc(stmt->capacity_edges * sizeof(edge_to_match_t));
            memset(edges, 0, stmt->capacity_edges * sizeof(edge_to_match_t));
            for (size_t i = 0; i < stmt->n_edges; i++) {
                edge_to_match_t* edge = statementEdgeAt(stmt, i);
                if (edge->type != EMPTY) { edges[n_edges++] = *edge; }
            }

            stmt->n_edges = n_edges;
            ckfree((char *)stmt->edges);
            stmt->edges = edges;
        }
        static void matchDefragmentEdges(match_t* match) {
            // Copy all non-EMPTY edges into a new edgelist.
            size_t n_edges = 0;
            edge_to_statement_t* edges = (edge_to_statement_t *)ckalloc(match->capacity_edges * sizeof(edge_to_statement_t));
            memset(edges, 0, match->capacity_edges * sizeof(edge_to_statement_t));
            for (size_t i = 0; i < match->n_edges; i++) {
                edge_to_statement_t* edge = &match->edges[i];
                if (edge->type != EMPTY) { edges[n_edges++] = *edge; }
            }

            match->n_edges = n_edges;
            ckfree((char *)match->edges);
            match->edges = edges;
        }
    }

    namespace export clause parentMatchIds childMatchIds
    $cc proc clause {Tcl_Obj* stmtobj} Tcl_Obj* {
        assert(stmtobj->typePtr == &statement_t_ObjType);
        return ((statement_t *)stmtobj->internalRep.ptrAndLongRep.ptr)->clause;
    }
    $cc proc edges {Tcl_Interp* interp Tcl_Obj* stmtobj} Tcl_Obj* {
        assert(stmtobj->typePtr == &statement_t_ObjType);
        statement_t* stmt = stmtobj->internalRep.ptrAndLongRep.ptr;
        Tcl_Obj* ret = Tcl_NewListObj(stmt->n_edges, NULL);
        for (size_t i = 0; i < stmt->n_edges; i++) {
            edge_to_match_t* edge = statementEdgeAt(stmt, i);
            Tcl_Obj* edgeobj = Tcl_NewObj();
            edgeobj->typePtr = &edge_to_match_t_ObjType;
            edgeobj->bytes = NULL;
            edgeobj->internalRep.ptrAndLongRep.ptr = edge;
            edgeobj->internalRep.ptrAndLongRep.value = 0;
            Tcl_ListObjAppendElement(interp, ret, edgeobj);
        }
        return ret;
    }
    proc parentMatchIds {stmt} {
        concat {*}[lmap edge [edges $stmt] {expr {
            [dict get $edge type] == 1 ? [list [dict get $edge match] true] : [continue]
        }}]
    }
    proc childMatchIds {stmt} {
        concat {*}[lmap edge [edges $stmt] {expr {
            [dict get $edge type] == 2 ? [list [dict get $edge match] true] : [continue]
        }}]
    }
    namespace ensemble create

    namespace export short
    proc short {stmt} {
        set lines [split [clause $stmt] "\n"]
        set line [lindex $lines 0]
        if {[string length $line] > 80} {set line "[string range $line 0 80]..."}
        format "{%s} %s {%s}" [parentMatchIds $stmt] $line [childMatchIds $stmt]
    }

    variable negations [list nobody nothing]
    variable blanks [list someone something anyone anything]

    # Splits a pattern by & into subpatterns, like
    #
    # `/thing/ is red & /thing/ is cool` ->
    #     `/thing/ is red`,
    #     `/thing/ is cool`
    #
    # Each subpattern in the out array is a new heap-allocated Tcl_Obj
    # and should be freed by the caller.
    $cc proc splitPattern {Tcl_Obj* pattern
                           int maxSubpatternsCount Tcl_Obj** outSubpatterns} int {
        int patternLength; Tcl_Obj** patternWords;
        Tcl_ListObjGetElements(NULL, pattern, &patternLength, &patternWords);
        int subpatternLength = 0;
        int subpatternsCount = 0;
        for (int i = 0; i <= patternLength; i++) {
            if (i == patternLength || strcmp(Tcl_GetString(patternWords[i]), "&") == 0) {
                Tcl_Obj* subpattern = Tcl_NewListObj(subpatternLength, &patternWords[i - subpatternLength]);
                outSubpatterns[subpatternsCount++] = subpattern;
                subpatternLength = 0;
            } else {
                subpatternLength++;
            }
        }
        return subpatternsCount;
    }

    # Converts a pattern from base form like `the time is /t/` to
    # claimized form, `/someone/ claims the time is /t/`. The returned
    # pattern is a new heap-allocated Tcl_Obj and should be freed by
    # the caller.
    $cc proc claimizePattern {Tcl_Obj* pattern} Tcl_Obj* {
        static Tcl_Obj* someoneClaims[2] = {0};
        if (someoneClaims[0] == NULL) {
            someoneClaims[0] = Tcl_NewStringObj("/someone/", -1);
            someoneClaims[1] = Tcl_NewStringObj("claims", -1);
            Tcl_IncrRefCount(someoneClaims[0]);
            Tcl_IncrRefCount(someoneClaims[1]);
        }

        // the time is /t/ -> /someone/ claims the time is /t/
        Tcl_Obj* ret = Tcl_DuplicateObj(pattern);
        Tcl_ListObjReplace(NULL, ret, 0, 0, 2, someoneClaims);
        return ret;
    }
}

namespace eval Statements { ;# singleton Statement store
    variable cc $::statement::cc
    namespace import ::statement::$cc

    $cc code [csubst {
        typedef struct trie trie_t;

        statement_t statements[32768];
        uint16_t nextStatementIdx = 1;
        trie_t* statementClauseToId;

        match_t matches[32768];
        uint16_t nextMatchIdx = 1;
    }]
    $cc proc statementClauseToIdTrie {} trie_t* {
        return statementClauseToId;
    }
    $cc proc matchNew {} match_handle_t {
        uint16_t origNextMatchIdx = nextMatchIdx;
        while (matches[nextMatchIdx].alive) {
            nextMatchIdx = (nextMatchIdx + 1) % (sizeof(matches)/sizeof(matches[0]));
            if (nextMatchIdx == origNextMatchIdx) {
                fprintf(stderr, "Ran out of space for new match\n"); exit(1);
            }
        }
        matches[nextMatchIdx].capacity_edges = 16;
        matches[nextMatchIdx].edges = (edge_to_statement_t*)ckalloc(16 * sizeof(edge_to_statement_t));
        matches[nextMatchIdx].isFromCollect = false;
        matches[nextMatchIdx].alive = true;
        return (match_handle_t) {
            .idx = nextMatchIdx,
            .gen = matches[nextMatchIdx].gen
        };
    }
    $cc proc matchGet {match_handle_t matchId} match_t* {
        if (matchId.gen != matches[matchId.idx].gen || !matches[matchId.idx].alive) {
            return NULL;
        }
        return &matches[matchId.idx];
    }
    $cc proc matchEdges {Tcl_Interp* interp match_handle_t matchId} Tcl_Obj* {
        match_t* match = matchGet(matchId);
        Tcl_Obj* ret = Tcl_NewListObj(match->n_edges, NULL);
        for (size_t i = 0; i < match->n_edges; i++) {
            edge_to_statement_t* edge = &match->edges[i];
            Tcl_Obj* edgeobj = Tcl_NewObj();
            edgeobj->typePtr = &edge_to_statement_t_ObjType;
            edgeobj->bytes = NULL;
            edgeobj->internalRep.ptrAndLongRep.ptr = edge;
            edgeobj->internalRep.ptrAndLongRep.value = 0;
            Tcl_ListObjAppendElement(interp, ret, edgeobj);
        }
        return ret;
    }
    $cc proc matchRemove {match_handle_t matchId} void {
        match_t* match = matchGet(matchId);
        for (int i = 0; i < sizeof(match->destructors)/sizeof(match->destructors[0]); i++) {
            if (match->destructors[i].body != NULL) {
                Tcl_DecrRefCount(match->destructors[i].body);
                Tcl_DecrRefCount(match->destructors[i].env);
                match->destructors[i].body = NULL;
                match->destructors[i].env = NULL;
            }
        }
        match->alive = false;
        match->gen++;
        match->n_edges = 0;
        ckfree((char*)match->edges);
    }
    $cc proc matchExists {match_handle_t matchId} bool {
        match_t* match = matchGet(matchId);
        return match != NULL && match->alive;
    }
    $cc proc matchAddDestructor {match_handle_t matchId Tcl_Obj* body Tcl_Obj* env} void {
        match_t* match = matchGet(matchId);
        for (int i = 0; i < sizeof(match->destructors)/sizeof(match->destructors[0]); i++) {
            if (match->destructors[i].body == NULL) {
                match->destructors[i].body = body;
                match->destructors[i].env = env;
                Tcl_IncrRefCount(body);
                Tcl_IncrRefCount(env);
                return;
            }
        }
        exit(10);
    }

    $cc proc new {} statement_handle_t {
        while (statements[nextStatementIdx].clause != NULL) {
            nextStatementIdx = (nextStatementIdx + 1) % (sizeof(statements)/sizeof(statements[0]));
        }
        return (statement_handle_t) {
            .idx = nextStatementIdx,
            .gen = statements[nextStatementIdx].gen
        };
    }
    $cc proc get {statement_handle_t id} statement_t* {
        if (id.gen != statements[id.idx].gen || statements[id.idx].clause == NULL) {
            return NULL;
        }
        return &statements[id.idx];
    }
    $cc proc deref {statement_t* ptr} statement_t { return *ptr; }
    $cc proc exists {statement_handle_t id} int {
        return get(id) != NULL;
    }
    $cc proc remove_ {statement_handle_t id} void {
        statement_t* stmt = get(id);

        int32_t gen = stmt->gen;
        Tcl_Obj* clause = stmt->clause;
        ckfree((char *)stmt->edges);
        memset(stmt, 0, sizeof(*stmt));
        trieRemove(NULL, statementClauseToId, clause);
        Tcl_DecrRefCount(clause);

        stmt->gen = gen;
        stmt->gen++;
    }
    $cc proc size {} size_t {
        size_t size = 0;
        for (int i = 0; i < sizeof(statements)/sizeof(statements[0]); i++) {
            if (statements[i].clause != NULL) { size++; }
        }
        return size;
    }

    $cc import ::ctrie::cc create as trieCreate
    $cc import ::ctrie::cc lookup as trieLookup
    $cc import ::ctrie::cc lookupLiteral as trieLookupLiteral
    $cc import ::ctrie::cc add as trieAdd
    $cc import ::ctrie::cc remove_ as trieRemove
    $cc import ::ctrie::cc scanVariable as scanVariable
    $cc proc StatementsInit {} void {
        statementClauseToId = trieCreate();
    }

    $cc proc addMatchImpl {size_t n_parents statement_handle_t parents[]} match_handle_t {
        match_handle_t matchId = matchNew();
        for (int i = 0; i < n_parents; i++) {
            matchAddEdgeToStatement(matchId, PARENT, parents[i]);
            statementAddEdgeToMatch(parents[i], CHILD, matchId);
        }

        return matchId;
    }
    proc addMatch {parentMatchIds} {
        addMatchImpl [llength $parentMatchIds] $parentMatchIds
    }

    $cc proc addImpl {Tcl_Interp* interp
                      Tcl_Obj* clause
                      size_t n_parents match_handle_t parents[]
                      statement_handle_t* outStatement
                      bool* outIsNewStatement} void {
        // Is this clause already present among the existing statements?
        uint64_t ids[10];
        int idslen = trieLookupLiteral(interp, ids, 10, statementClauseToId, clause);
        statement_handle_t id;
        if (idslen == 1) {
            id = *(statement_handle_t *)&ids[0];
        } else if (idslen == 0) {
            id.idx = -1;
        } else {
            // error WTF
            printf("WTF: looked up %s\n", Tcl_GetString(clause));
            exit(1);
        }

        bool isNewStatement = (id.idx == -1);
        if (isNewStatement) {
            id = new();

            // Unguarded access to statement because it's still uncreated at this point.
            statements[id.idx] = statementCreate(clause, n_parents, parents, 0, NULL);
            statements[id.idx].gen = id.gen;
            trieAdd(interp, &statementClauseToId, clause, *(uint64_t*)&id);

        } else {
            for (size_t i = 0; i < n_parents; i++) {
                statementAddEdgeToMatch(id, PARENT, parents[i]);
            }
        }

        for (size_t i = 0; i < n_parents; i++) {
            if (parents[i].idx == -1) { continue; } // ?
            matchAddEdgeToStatement(parents[i], CHILD, id);
        }

        *outStatement = id;
        *outIsNewStatement = isNewStatement;
    }
    proc add {clause {parents {{idx -1} true}}} {
        addImpl $clause [dict size $parents] [dict keys $parents]
    }
    $cc code {
        static statement_t* get(statement_handle_t id);
        void statementRealloc(statement_handle_t id) {
            statement_t* stmt = get(id);
            assert(stmt != NULL);
            stmt->edges = (edge_to_match_t *)ckrealloc((char *)stmt->edges, stmt->capacity_edges*sizeof(edge_to_match_t));
        }
        void statementAddEdgeToMatch(statement_handle_t statementId,
                                     edge_type_t type, match_handle_t matchId) {
            statement_t* stmt = get(statementId);
            if (stmt->n_edges == stmt->capacity_edges) {
                // We've run out of edge slots at the end of the
                // statement. Try defragmenting the statement.
                statementDefragmentEdges(stmt);
                if (stmt->n_edges == stmt->capacity_edges) {
                    // Still no slots? Grow the statement to
                    // accommodate.
                    stmt->capacity_edges = stmt->capacity_edges * 2;
                    statementRealloc(statementId);
                }
            }

            assert(stmt->n_edges < stmt->capacity_edges);
            // There's a free slot at the end of the edgelist in
            // the statement. Use it.
            stmt->edges[stmt->n_edges++] = (edge_to_match_t) { .type = type, .match = matchId };
        }
        int statementRemoveEdgeToMatch(statement_handle_t statementId,
                                       edge_type_t type, match_handle_t matchId) {
            statement_t* stmt = get(statementId);
            assert(stmt != NULL);
            int parentEdges = 0;
            for (size_t i = 0; i < stmt->n_edges; i++) {
                edge_to_match_t* edge = statementEdgeAt(stmt, i);
                if (edge->type == type && matchHandleIsEqual(edge->match, matchId)) {
                    edge->type = EMPTY;
                    edge->match = (match_handle_t) {0};
                }
                if (edge->type == PARENT) { parentEdges++; }
            }
            return parentEdges;
        }
        static match_t* matchGet(match_handle_t id);
        void matchRealloc(match_handle_t id) {
            match_t* match = matchGet(id);
            assert(match != NULL);
            match->edges = (edge_to_statement_t *)ckrealloc((char *)match->edges, match->capacity_edges*sizeof(edge_to_statement_t));
        }
        void matchAddEdgeToStatement(match_handle_t matchId,
                                     edge_type_t type, statement_handle_t statementId) {
            match_t* match = matchGet(matchId);
            if (match->n_edges == match->capacity_edges) {
                // We've run out of edge slots at the end of the
                // match. Try defragmenting the match.
                matchDefragmentEdges(match);
                if (match->n_edges == match->capacity_edges) {
                    // Still no slots? Grow the match to accommodate.
                    match->capacity_edges = match->capacity_edges * 2;
                    matchRealloc(matchId);
                }
            }

            assert(match->n_edges < match->capacity_edges);
            match->edges[match->n_edges++] = (edge_to_statement_t) { .type = type, .statement = statementId };
        }
        void matchRemoveEdgeToStatement(match_handle_t matchId,
                                        edge_type_t type, statement_handle_t statementId) {
            match_t* match = matchGet(matchId);
            assert(match != NULL);
            for (size_t i = 0; i < match->n_edges; i++) {
                edge_to_statement_t* edge = &match->edges[i];
                if (edge->type == type &&
                    statementHandleIsEqual(edge->statement, statementId)) {
                    edge->type = EMPTY;
                    edge->statement = (statement_handle_t) {0};
                }
            }
            // TODO: compact
        }
    }

    $cc struct environment_binding_t {
        char name[100];
        Tcl_Obj* value;
    }
    $cc struct environment_t {
        // This environment corresponds to a single concrete match.

        // One statement ID for each pattern in the join.
        int matchedStatementIdsCount;
        statement_handle_t matchedStatementIds[10];

        int bindingsCount;
        environment_binding_t bindings[1];
    }
    $cc code {
        Tcl_Obj* environmentLookup(environment_t* env, const char* varName) {
            for (int i = 0; i < env->bindingsCount; i++) {
                if (strcmp(env->bindings[i].name, varName) == 0) {
                    return env->bindings[i].value;
                }
            }
            return NULL;
        }
        Tcl_Obj* environmentToTclDict(environment_t* env) {
            Tcl_Obj* ret = Tcl_NewDictObj();
            for (int i = 0; i < env->bindingsCount; i++) {
                Tcl_DictObjPut(NULL, ret,
                               Tcl_NewStringObj(env->bindings[i].name, -1),
                               env->bindings[i].value);
            }
            return ret;
        }
    }

    # unify allocates a new environment.
    $cc proc isBlank {char* varName} bool [subst {
        [join [lmap blank $statement::blanks {subst {
            if (strcmp(varName, "$blank") == 0) { return true; }
        }}] "\n"]
        return false;
    }]
    $cc proc unify {Tcl_Obj* a Tcl_Obj* b} environment_t* {
        int alen; Tcl_Obj** awords;
        int blen; Tcl_Obj** bwords;
        Tcl_ListObjGetElements(NULL, a, &alen, &awords);
        Tcl_ListObjGetElements(NULL, b, &blen, &bwords);

        environment_t* env = (environment_t*)ckalloc(sizeof(environment_t) + sizeof(environment_binding_t)*alen);
        memset(env, 0, sizeof(*env));
        for (int i = 0; i < alen; i++) {
            char aVarName[100] = {0}; char bVarName[100] = {0};
            if (scanVariable(awords[i], aVarName, sizeof(aVarName))) {
                if (aVarName[0] == '.' && aVarName[1] == '.' && aVarName[2] == '.') {
                    environment_binding_t* binding = &env->bindings[env->bindingsCount++];
                    memcpy(binding->name, aVarName, sizeof(binding->name));
                    binding->value = Tcl_NewListObj(blen - i, &bwords[i]);

                } else if (!isBlank(aVarName)) {
                    environment_binding_t* binding = &env->bindings[env->bindingsCount++];
                    memcpy(binding->name, aVarName, sizeof(binding->name));
                    binding->value = bwords[i];
                }
            } else if (scanVariable(bwords[i], bVarName, sizeof(bVarName))) {
                if (bVarName[0] == '.' && bVarName[1] == '.' && bVarName[2] == '.') {
                    environment_binding_t* binding = &env->bindings[env->bindingsCount++];
                    memcpy(binding->name, bVarName, sizeof(binding->name));
                    binding->value = Tcl_NewListObj(alen - i, &awords[i]);

                } else if (!isBlank(bVarName)) {
                    environment_binding_t* binding = &env->bindings[env->bindingsCount++];
                    memcpy(binding->name, bVarName, sizeof(binding->name));
                    binding->value = awords[i];
                }
            } else if (!(awords[i] == bwords[i] ||
                         strcmp(Tcl_GetString(awords[i]), Tcl_GetString(bwords[i])) == 0)) {
                ckfree((char *)env);
                fprintf(stderr, "unification wrt (%s) (%s) failed\n", Tcl_GetString(a), Tcl_GetString(b));
                return NULL;
            }
        }
        return env;
    }
    $cc proc searchByPattern {Tcl_Obj* pattern
                              int maxResultsCount environment_t** outResults} int {
        uint64_t ids[maxResultsCount];
        int idsCount = trieLookup(NULL, ids, maxResultsCount, statementClauseToId, pattern);

        int resultsCount = 0;
        for (int i = 0; i < idsCount; i++) {
            statement_handle_t id = *(statement_handle_t *)&ids[i];
            environment_t* result = unify(pattern, get(id)->clause);
            if (result != NULL) {
                result->matchedStatementIdsCount = 1;
                result->matchedStatementIds[0] = id;
                outResults[resultsCount++] = result;
            }
        }
        return resultsCount;
    }
    $cc proc findMatches {Tcl_Obj* pattern} Tcl_Obj* {
        Tcl_Obj* ret = Tcl_NewListObj(0, NULL);

        environment_t* results[1000];
        int resultsCount = searchByPattern(pattern, 1000, results);
        for (int i = 0; i < resultsCount; i++) {
            Tcl_Obj* matchObj = environmentToTclDict(results[i]);
            statement_handle_t id = results[i]->matchedStatementIds[0];
            Tcl_DictObjPut(NULL, matchObj, Tcl_ObjPrintf("__matcheeIds"), Tcl_ObjPrintf("{s%d:%d}", id.idx, id.gen));
            Tcl_ListObjAppendElement(NULL, ret, matchObj);
            ckfree((char *)results[i]);
        }
        return ret;
    }

    $cc proc count {Tcl_Obj* pattern} int {
        environment_t* outResults[1000];
        return searchByPattern(pattern, 1000, outResults);
    }
    $cc proc searchByPatterns {int patternsCount Tcl_Obj* patterns[]
                               environment_t* env
                               int maxResultsCount environment_t** outResults
                               int* outResultsCount} void {
        // Do substitution of bindings into first pattern
        Tcl_Obj* substitutedFirstPattern = Tcl_DuplicateObj(patterns[0]);
        int wordCount; Tcl_Obj** words;
        Tcl_ListObjGetElements(NULL, substitutedFirstPattern,
                               &wordCount, &words);
        for (int i = 0; i < wordCount; i++) {
            char varName[100]; Tcl_Obj* boundValue = NULL;
            if (scanVariable(words[i], varName, sizeof(varName)) &&
                env != NULL &&
                (boundValue = environmentLookup(env, varName))) {

                Tcl_ListObjReplace(NULL, substitutedFirstPattern, i, 1,
                                   1, &boundValue);
            }
        }

        environment_t* resultsForFirstPattern[maxResultsCount];
        int resultsForFirstPatternCount = searchByPattern(substitutedFirstPattern,
                                                          maxResultsCount, resultsForFirstPattern);
        Tcl_Obj* claimizedSubstitutedFirstPattern = claimizePattern(substitutedFirstPattern);
        resultsForFirstPatternCount += searchByPattern(claimizedSubstitutedFirstPattern,
                                                       maxResultsCount - resultsForFirstPatternCount, &resultsForFirstPattern[resultsForFirstPatternCount]);
        Tcl_DecrRefCount(substitutedFirstPattern);
        Tcl_DecrRefCount(claimizedSubstitutedFirstPattern);
        for (int i = 0; i < resultsForFirstPatternCount; i++) {
            environment_t* result = resultsForFirstPattern[i];
            if (env != NULL) {
                memcpy(&result->matchedStatementIds[result->matchedStatementIdsCount],
                       &env->matchedStatementIds[0],
                       sizeof(env->matchedStatementIds[0])*env->matchedStatementIdsCount);
                result->matchedStatementIdsCount += env->matchedStatementIdsCount;
                memcpy(&result->bindings[result->bindingsCount],
                       &env->bindings[0],
                       sizeof(env->bindings[0])*env->bindingsCount);
                result->bindingsCount += env->bindingsCount;
            }
            if (patternsCount - 1 == 0) {
                outResults[(*outResultsCount)++] = result;
            } else {
                searchByPatterns(patternsCount - 1, &patterns[1],
                                 result,
                                 maxResultsCount - 1, outResults,
                                 outResultsCount);
                ckfree((char *)result);
            }
        }
    }
    $cc proc findMatchesJoining {Tcl_Obj* patterns Tcl_Obj* bindings} Tcl_Obj* {
        environment_t* results[1000];
        int patternsCount; Tcl_Obj** patternsObjs;
        Tcl_ListObjGetElements(NULL, patterns, &patternsCount, &patternsObjs);
        int resultsCount = 0;

        environment_t* env = (environment_t*)ckalloc(sizeof(environment_t) + 10*sizeof(environment_binding_t));
        memset(env, 0, sizeof(*env));
        Tcl_DictSearch search;
        Tcl_Obj *key, *value;
        int done;
        if (Tcl_DictObjFirst(NULL, bindings, &search,
                             &key, &value, &done) != TCL_OK) {
            exit(2);
        }
        for (; !done ; Tcl_DictObjNext(&search, &key, &value, &done)) {
            environment_binding_t* b = &env->bindings[env->bindingsCount++];
            int nameLen; char* namePtr = Tcl_GetStringFromObj(key, &nameLen);
            memcpy(b->name, namePtr, nameLen);
            b->value = value;
        }
        Tcl_DictObjDone(&search);
        searchByPatterns(patternsCount, patternsObjs,
                         env,
                         1000, results, &resultsCount);
        ckfree((char *)env);

        Tcl_Obj* ret = Tcl_NewListObj(0, NULL);
        for (int i = 0; i < resultsCount; i++) {
            // TODO: Emit __matcheeIds properly based on results[i]
            Tcl_ListObjAppendElement(NULL, ret, environmentToTclDict(results[i]));
            ckfree((char *)results[i]);
        }
        return ret;
    }

    $cc proc all {} Tcl_Obj* {
        Tcl_Obj* ret = Tcl_NewListObj(0, NULL);
        for (int i = 0; i < sizeof(statements)/sizeof(statements[0]); i++) {
            if (statements[i].clause == NULL) continue;
            Tcl_Obj* s = Tcl_NewObj();
            s->bytes = NULL;
            s->typePtr = &statement_t_ObjType;
            s->internalRep.ptrAndLongRep.ptr = &statements[i];
            s->internalRep.ptrAndLongRep.value = 0;

            Tcl_ListObjAppendElement(NULL, ret, Tcl_ObjPrintf("s%d:%d", i, statements[i].gen));
            Tcl_ListObjAppendElement(NULL, ret, s);
        }
        return ret;
    }
    proc dot {} {
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
    proc saveDotToPdf {filename} {
        exec dot -Tpdf >$filename <<[Statements::dot]
    }

    proc print {} {
        dict for {id stmt} [Statements::all] {
            puts [statement short $stmt]
        }
    }

    # these are kind of arbitrary/temporary bridge
    $cc proc matchRemoveFirstDestructor {match_handle_t matchId} void {
        Tcl_DecrRefCount(matchGet(matchId)->destructors[0].body);
        Tcl_DecrRefCount(matchGet(matchId)->destructors[0].env);
        matchGet(matchId)->destructors[0].body = NULL;
        matchGet(matchId)->destructors[0].env = NULL;
    }
}

namespace eval Evaluator {
    variable cc $::statement::cc
    namespace import ::statement::$cc

    $cc code {
        #include <stdarg.h>
        char operationLog[10000][1000];
        int operationLogIdx = 0;
        void op(const char *format, ...) {
            if (operationLogIdx >= 10000) return;

            va_list args;
            va_start(args, format);
            // vprintf(format, args); printf("\n");
            vsnprintf(operationLog[operationLogIdx++], 1000, format, args);
            va_end(args);
        }
    }
    $cc proc getOperationLog {} Tcl_Obj* {
        Tcl_Obj* entries[10000];
        int i;
        for (i = 0; i < 10000 && operationLog[i][0] != '\0'; i++) {
            entries[i] = Tcl_NewStringObj(operationLog[i], -1);
        }
        return Tcl_NewListObj(i, entries);
    }

    $cc code {
        // Given a StatementPattern, tells you all the reactions to run
        // when a matching statement is added to / removed from the
        // database. StatementId is the ID of the statement that wanted to
        // react.
        //
        // For example, if you add `When the time is /t/`, it will register
        // a reaction to the addition and removal of statements matching
        // the pattern `the time is /t/`.
        //
        // Trie<StatementPattern + StatementId, Reaction>
        trie_t* reactionsToStatementAddition;
        // Used to quickly remove reactions when the reacting statement is removed:
        // Dict<StatementId, List<StatementPattern + StatementId>>
        Tcl_Obj* reactionPatternsOfReactingId[32768];
        typedef void (*reaction_fn_t)(Tcl_Interp* interp,
                                      statement_handle_t reactingId,
                                      Tcl_Obj* reactToPattern,
                                      statement_handle_t newStatementId);
        typedef struct reaction_t {
            reaction_fn_t react;
            statement_handle_t reactingId;
            Tcl_Obj* reactToPattern;
        } reaction_t;

        void addReaction(Tcl_Obj* reactToPattern, statement_handle_t reactingId, reaction_fn_t react) {
            reaction_t *reaction = (reaction_t*)ckalloc(sizeof(reaction_t));
            reaction->react = react;
            reaction->reactingId = reactingId;
            Tcl_IncrRefCount(reactToPattern);
            reaction->reactToPattern = reactToPattern;

            Tcl_Obj* reactToPatternAndReactingId = Tcl_DuplicateObj(reactToPattern);
            Tcl_Obj* reactingIdObj = Tcl_NewIntObj(reactingId.idx);
            int reactToPatternLength; Tcl_ListObjLength(NULL, reactToPattern, &reactToPatternLength);
            Tcl_ListObjReplace(NULL, reactToPatternAndReactingId, reactToPatternLength, 0, 1, &reactingIdObj);
            trieAdd(NULL, &reactionsToStatementAddition, reactToPatternAndReactingId, (uintptr_t)reaction);

            if (reactionPatternsOfReactingId[reactingId.idx] == NULL) {
                reactionPatternsOfReactingId[reactingId.idx] = Tcl_NewListObj(0, NULL);
                Tcl_IncrRefCount(reactionPatternsOfReactingId[reactingId.idx]);
            }
            Tcl_ListObjAppendElement(NULL, reactionPatternsOfReactingId[reactingId.idx],
                                     reactToPatternAndReactingId);
        }
        void removeAllReactions(statement_handle_t reactingId) {
            if (reactionPatternsOfReactingId[reactingId.idx] == NULL) { return; }
            int patternCount; Tcl_Obj** patterns;
            Tcl_ListObjGetElements(NULL, reactionPatternsOfReactingId[reactingId.idx],
                                   &patternCount, &patterns);
            for (int i = 0; i < patternCount; i++) {
                uint64_t reactionPtrs[1000];
                int reactionsCount = trieLookupLiteral(NULL, reactionPtrs, 1000,
                                                       reactionsToStatementAddition, patterns[i]);
                for (int j = 0; j < reactionsCount; j++) {
                    reaction_t* reaction = (reaction_t*)(uintptr_t) reactionPtrs[j];
                    Tcl_DecrRefCount(reaction->reactToPattern);
                    ckfree((char *)reaction);
                }
                trieRemove(NULL, reactionsToStatementAddition, patterns[i]);
            }
            Tcl_DecrRefCount(reactionPatternsOfReactingId[reactingId.idx]);
            reactionPatternsOfReactingId[reactingId.idx] = NULL;
        }

        void tryRunInSerializedEnvironment(Tcl_Interp* interp, Tcl_Obj* lambda, Tcl_Obj* env) {
            int objc = 3; Tcl_Obj *objv[3];
            objv[0] = Tcl_NewStringObj("Evaluator::tryRunInSerializedEnvironment", -1);
            objv[1] = lambda;
            objv[2] = env;
            if (Tcl_EvalObjv(interp, objc, objv, 0) == TCL_ERROR) {
                printf("oh god: %s\n", Tcl_GetString(Tcl_GetObjResult(interp)));
            }
        }
        static statement_t* get(statement_handle_t id);
        static int exists(statement_handle_t id);
        static match_handle_t addMatchImpl(size_t n_parents, statement_handle_t parents[]);
        static environment_t* unify(Tcl_Obj* a, Tcl_Obj* b);
        void reactToStatementAdditionThatMatchesWhen(Tcl_Interp* interp,
                                                     statement_handle_t whenId,
                                                     Tcl_Obj* whenPattern,
                                                     statement_handle_t statementId) {
            if (!exists(whenId)) {
                removeAllReactions(whenId);
                return;
            }
            statement_t* when = get(whenId);
            statement_t* stmt = get(statementId);

            environment_t* result = unify(whenPattern, stmt->clause);
            if (result) {
                int whenClauseLength; Tcl_ListObjLength(NULL, when->clause, &whenClauseLength);

                statement_handle_t matchParentIds[] = {whenId, statementId};
                match_handle_t matchId = addMatchImpl(2, matchParentIds);
                Tcl_Obj* lambda; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-4, &lambda);
                Tcl_Obj* env; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-1, &env);

                env = Tcl_DuplicateObj(env);
                // Append bindings to end of env
                // TODO: does this preserve order?
                // FIXME: need to only get bindings on the When side
                for (int i = 0; i < result->bindingsCount; i++) {
                    /* printf("Appending binding: [%s]->[%s]\n", result->bindings[i].name, Tcl_GetString(result->bindings[i].value)); */
                    Tcl_ListObjAppendElement(interp, env, result->bindings[i].value);
                }
                ckfree((char*)result);

                Tcl_ObjSetVar2(interp, Tcl_ObjPrintf("::matchId"), NULL, Tcl_ObjPrintf("m%d:%d", matchId.idx, matchId.gen), 0);
                tryRunInSerializedEnvironment(interp, lambda, env);
            }
        }
        static void LogWriteRecollect(statement_handle_t collectId);
        static void LogWriteUnmatch(match_handle_t matchId);
        void reactToStatementAdditionThatMatchesCollect(Tcl_Interp* interp,
                                                        statement_handle_t collectId,
                                                        Tcl_Obj* collectPattern,
                                                        statement_handle_t statementId) {
            get(collectId)->collectNeedsRecollect = true;
            LogWriteRecollect(collectId);
        }
    }
    
    $cc proc EvaluatorInit {} void {
        reactionsToStatementAddition = trieCreate();
    }

    $cc proc reactToStatementAddition {Tcl_Interp* interp statement_handle_t id} void {
        Tcl_Obj* clause = get(id)->clause;
        int clauseLength; Tcl_Obj** clauseWords;
        Tcl_ListObjGetElements(interp, clause, &clauseLength, &clauseWords);

        if (strcmp(Tcl_GetString(clauseWords[0]), "when") == 0 &&
            strcmp(Tcl_GetString(clauseWords[1]), "the") == 0 &&
            strcmp(Tcl_GetString(clauseWords[2]), "collected") == 0 &&
            strcmp(Tcl_GetString(clauseWords[3]), "matches") == 0 &&
            strcmp(Tcl_GetString(clauseWords[4]), "for") == 0) {

            // when the collected matches for [list the time is /t/ & Omar is cool] are /matches/ { ... } with environment /__env/
            //   -> {the time is /t/} {Omar is cool}
            Tcl_Obj* pattern = clauseWords[5];
            Tcl_Obj* subpatterns[10];
            int subpatternsCount = splitPattern(pattern, 10, subpatterns);
            for (int i = 0; i < subpatternsCount; i++) {
                Tcl_Obj* subpattern = subpatterns[i];
                addReaction(subpattern, id, reactToStatementAdditionThatMatchesCollect);
                addReaction(claimizePattern(subpattern), id, reactToStatementAdditionThatMatchesCollect);
            }

            get(id)->collectNeedsRecollect = true;
            LogWriteRecollect(id);

        } else if (strcmp(Tcl_GetString(clauseWords[0]), "when") == 0) {
            // when the time is /t/ { ... } with environment /env/ -> the time is /t/
            Tcl_Obj* pattern = Tcl_DuplicateObj(clause);
            Tcl_ListObjReplace(interp, pattern, clauseLength-4, 4, 0, NULL);
            Tcl_ListObjReplace(interp, pattern, 0, 1, 0, NULL);
            addReaction(pattern, id, reactToStatementAdditionThatMatchesWhen);
            Tcl_Obj* claimizedPattern = claimizePattern(pattern);
            addReaction(claimizedPattern, id, reactToStatementAdditionThatMatchesWhen);

            // Scan the existing statement set for any
            // already-existing matching statements.
            uint64_t alreadyMatchingStatementIds[1000];
            int alreadyMatchingStatementIdsCount = trieLookup(interp, alreadyMatchingStatementIds, 1000,
                                                              statementClauseToId, pattern);
            for (int i = 0; i < alreadyMatchingStatementIdsCount; i++) {
                statement_handle_t alreadyMatchingStatementId = *(statement_handle_t *)&alreadyMatchingStatementIds[i];
                reactToStatementAdditionThatMatchesWhen(interp, id, pattern, alreadyMatchingStatementId);
            }
            alreadyMatchingStatementIdsCount = trieLookup(interp, alreadyMatchingStatementIds, 1000,
                                                          statementClauseToId, claimizedPattern);
            for (int i = 0; i < alreadyMatchingStatementIdsCount; i++) {
                statement_handle_t alreadyMatchingStatementId = *(statement_handle_t *)&alreadyMatchingStatementIds[i];
                reactToStatementAdditionThatMatchesWhen(interp, id, claimizedPattern, alreadyMatchingStatementId);
            }
        }

        // Trigger any reactions to the addition of this statement.
        Tcl_Obj* clauseWithReactingIdWildcard = Tcl_DuplicateObj(clause); {
            Tcl_Obj* reactingIdWildcard = Tcl_ObjPrintf("/reactingId/");
            Tcl_ListObjReplace(interp, clauseWithReactingIdWildcard, clauseLength, 0,
                               1, &reactingIdWildcard);
        }
        uint64_t reactions[1000];
        int reactionCount = trieLookup(interp, reactions, 1000,
                                       reactionsToStatementAddition, clauseWithReactingIdWildcard);
        Tcl_DecrRefCount(clauseWithReactingIdWildcard);
        for (int i = 0; i < reactionCount; i++) {
            reaction_t* reaction = (reaction_t*)(uintptr_t)reactions[i];
            reaction->react(interp, reaction->reactingId, reaction->reactToPattern, id);
        }
    }
    $cc code { static void reactToStatementRemoval(Tcl_Interp* interp, statement_handle_t id); }
    $cc proc reactToMatchRemoval {Tcl_Interp* interp match_handle_t matchId} void {
        match_t* match = matchGet(matchId);

        for (int j = 0; j < match->n_edges; j++) {
            // this match will be dead, so remove the match from the
            // other parents of the match
            if (match->edges[j].type == PARENT) {
                statement_handle_t parentId = match->edges[j].statement;
                if (!exists(parentId)) { continue; }

                statementRemoveEdgeToMatch(parentId, CHILD, matchId);

            } else if (match->edges[j].type == CHILD) {
                statement_handle_t childId = match->edges[j].statement;
                if (!exists(childId)) { continue; }

                if (statementRemoveEdgeToMatch(childId, PARENT, matchId) == 0) {
                    // is this child statement out of parent matches? => it's dead
                    reactToStatementRemoval(interp, childId);
                    remove_(childId);
                    matchRemoveEdgeToStatement(matchId, CHILD, childId);
                }
            }
        }

        for (int i = 0; i < sizeof(match->destructors)/sizeof(match->destructors[0]); i++) {
            if (match->destructors[i].body != NULL) {
                tryRunInSerializedEnvironment(interp, match->destructors[i].body, match->destructors[i].env);
            }
        }
    }
    $cc proc reactToStatementRemoval {Tcl_Interp* interp statement_handle_t id} void {
        // unset all things downstream of statement
        removeAllReactions(id);
        statement_t* stmt = get(id);
        for (int i = 0; i < stmt->n_edges; i++) {
            edge_to_match_t* edge = statementEdgeAt(stmt, i);
            if (edge->type == PARENT) {
                match_handle_t matchId = edge->match;
                if (!matchExists(matchId)) continue;

                matchRemoveEdgeToStatement(matchId, CHILD, id);

            } else if (edge->type == CHILD) {
                match_handle_t matchId = edge->match;
                if (!matchExists(matchId)) continue; // if was removed earlier

                // Test if this child-match is a Collect-match (and
                // the statement being removed is _not_ its collector)
                match_t* match = matchGet(matchId);
                if (match->isFromCollect && !statementHandleIsEqual(match->collectId, id)) {
                    // If so, then it should be marked as dirty and
                    // recollected later, rather than it and its
                    // transitive dependents immediately getting
                    // yanked out.
                    if (exists(match->collectId)) {
                        get(match->collectId)->collectNeedsRecollect = true;
                        LogWriteRecollect(match->collectId);
                    } else {
                        reactToMatchRemoval(interp, matchId);
                        matchRemove(matchId);
                    }
                } else {
                    reactToMatchRemoval(interp, matchId);
                    matchRemove(matchId);
                    // LogWriteUnmatch(matchId);
                }
            }
        }
    }
    $cc proc UnmatchImpl {Tcl_Interp* interp match_handle_t currentMatchId int level} void {
        match_handle_t unmatchId = currentMatchId;
        for (int i = 0; i < level; i++) {
            match_t* unmatch = matchGet(unmatchId);
            // Get first parent of unmatchId (should be the When)
            for (int j = 0; j < unmatch->n_edges; j++) {
                if (unmatch->edges[j].type == PARENT) {
                    statement_handle_t unmatchWhenId = unmatch->edges[j].statement;
                    statement_t* unmatchWhen = get(unmatchWhenId);
                    if (unmatchWhen == NULL) continue;
                    for (int k = 0; k < unmatchWhen->n_edges; k++) {
                        if (unmatchWhen->edges[k].type == PARENT) {
                            unmatchId = unmatchWhen->edges[k].match;
                            break;
                        }
                    }
                    break;
                }
            }
        }
        reactToMatchRemoval(interp, unmatchId);
        matchRemove(unmatchId);
    }
    proc Unmatch {{level 0}} {
        # Forces an unmatch of the current match or its `level`-th ancestor match.
        UnmatchImpl $::matchId $level
    }

    $cc proc recollect {Tcl_Interp* interp statement_handle_t collectId} void {
        // Called when a statement of a pattern that someone is
        // collecting has been added or removed.

        statement_t* collect = get(collectId);
        if (!collect->collectNeedsRecollect) { return; }
        collect->collectNeedsRecollect = false;

        Tcl_Obj* clause = collect->clause;
        int clauseLength; Tcl_Obj** clauseWords;
        Tcl_ListObjGetElements(interp, clause, &clauseLength, &clauseWords);

        Tcl_Obj* lambda = clauseWords[clauseLength-4];
        char matchesVarName[100];
        scanVariable(clauseWords[clauseLength-5], matchesVarName, sizeof(matchesVarName));
        Tcl_Obj* env = clauseWords[clauseLength-1];

        int resultsCount = 0; environment_t* results[1000]; {
            Tcl_Obj* pattern = clauseWords[5];
            Tcl_Obj* subpatterns[10];
            int subpatternsCount = splitPattern(pattern, 10, subpatterns);
            searchByPatterns(subpatternsCount, subpatterns,
                             NULL,
                             1000, results,
                             &resultsCount);
            for (int i = 0; i < subpatternsCount; i++) {
                Tcl_DecrRefCount(subpatterns[i]);
            }
        }

        Tcl_Obj* matches = Tcl_NewListObj(0, NULL);

        int parentsCount = 1;
        statement_handle_t parents[resultsCount*10];
        parents[0] = collectId;
        for (int i = 0; i < resultsCount; i++) {
            Tcl_ListObjAppendElement(NULL, matches, environmentToTclDict(results[i]));
            for (int j = 0; j < results[i]->matchedStatementIdsCount; j++) {
                parents[parentsCount++] = results[i]->matchedStatementIds[j];
            }
            ckfree((char *)results[i]);
        }

        // Create a new match for the new collection.
        match_handle_t matchId = addMatchImpl(parentsCount, parents);
        match_t* match = matchGet(matchId);
        match->isFromCollect = true;
        match->collectId = collectId;

        // Run the When body within this new match.
        env = Tcl_DuplicateObj(env);
        Tcl_ListObjAppendElement(NULL, env, matches);
        Tcl_ObjSetVar2(interp, Tcl_ObjPrintf("::matchId"), NULL, Tcl_ObjPrintf("m%d:%d", matchId.idx, matchId.gen), 0);
        tryRunInSerializedEnvironment(interp, lambda, env);

        // Finally, delete the old match child if any.
        // (We do this last, _after_ adding the new match, because it helps with incrementality.)
        for (size_t i = 0; i < collect->n_edges; i++) {
            edge_to_match_t* edge = statementEdgeAt(collect, i);
            if (edge->type == CHILD && !matchHandleIsEqual(edge->match, matchId)) {
                match_handle_t childMatchId = edge->match;
                // We don't want to fire a new recollect on
                // destruction. (because we just fired one)
                matchGet(childMatchId)->isFromCollect = false;

                // This Unmatch has to be trampolined back up to
                // the operation log so it happens after Saying
                // any new statements.
                LogWriteUnmatch(childMatchId);
                break;
            }
        }
    }

    $cc cflags -I./vendor/libpqueue vendor/libpqueue/pqueue.c
    $cc include "pqueue.h"
    $cc code {
        typedef enum {
            NONE, ASSERT, RETRACT, SAY, UNMATCH, RECOLLECT
        } queue_op_t;
        typedef struct queue_entry_t {
            queue_op_t op;
            int seq;

            union {
                struct { Tcl_Obj* clause; } assert;
                struct { Tcl_Obj* pattern; } retract;
                struct {
                    match_handle_t parentMatchId;
                    Tcl_Obj* clause;
                } say;
                struct { match_handle_t matchId; } unmatch;
                struct { statement_handle_t collectId; } recollect;
            };
        } queue_entry_t;

        pqueue_t* queue;
        int seq;

        int queueEntryCompare(pqueue_pri_t next, pqueue_pri_t curr) {
            return next < curr;
        }
        pqueue_pri_t queueEntryGetPriority(void* a) {
            queue_entry_t* entry = a;
            switch (entry->op) {
                case NONE: return 0;

                case ASSERT:
                case RETRACT: return 80000 - entry->seq;
                case SAY: return 80000 + entry->seq;

                case UNMATCH: return 1000 - entry->seq;
                case RECOLLECT: return 5000 - entry->seq;
            }
            return 0;
        }
        void queueEntrySetPriority(void* a, pqueue_pri_t pri) {}
        size_t queueEntryGetPosition(void* a) { return 0; }
        void queueEntrySetPosition(void* a, size_t pos) {}
    }
    $cc proc init {} void {
        queue = pqueue_init(16384,
                            queueEntryCompare,
                            queueEntryGetPriority,
                            queueEntrySetPriority,
                            queueEntryGetPosition,
                            queueEntrySetPosition);
    }
    $cc proc Evaluate {Tcl_Interp* interp} void {
        op("Evaluate");

        seq = 0;

        queue_entry_t* entryPtr;
        while ((entryPtr = pqueue_pop(queue)) != NULL) {
            queue_entry_t entry = *entryPtr; ckfree((char*) entryPtr);
            if (entry.op == ASSERT) {
                op("Assert (%s)", Tcl_GetString(entry.assert.clause));
                statement_handle_t id; bool isNewStatement;
                addImpl(interp, entry.assert.clause, 0, NULL,
                        &id, &isNewStatement);
                if (isNewStatement) {
                    reactToStatementAddition(interp, id);
                }
                Tcl_DecrRefCount(entry.assert.clause);

            } else if (entry.op == RETRACT) {
                op("Retract (%s)", Tcl_GetString(entry.retract.pattern));
                environment_t* results[1000];
                int resultsCount = searchByPattern(entry.retract.pattern,
                                                   1000, results);
                for (int i = 0; i < resultsCount; i++) {
                    statement_handle_t id = results[i]->matchedStatementIds[0];
                    reactToStatementRemoval(interp, id);
                    remove_(id);
                    ckfree((char *)results[i]);
                }
                Tcl_DecrRefCount(entry.retract.pattern);

            } else if (entry.op == SAY) {
                op("Say (%s)", Tcl_GetString(entry.say.clause));
                if (matchExists(entry.say.parentMatchId)) {
                    statement_handle_t id; bool isNewStatement;
                    addImpl(interp, entry.say.clause, 1, &entry.say.parentMatchId,
                            &id, &isNewStatement);
                    if (isNewStatement) {
                        reactToStatementAddition(interp, id);
                    }
                }
                Tcl_DecrRefCount(entry.say.clause);

            } else if (entry.op == UNMATCH) {
                op("Unmatch (m%d:%d)", entry.unmatch.matchId.idx, entry.unmatch.matchId.gen);
                if (matchExists(entry.unmatch.matchId)) {
                    reactToMatchRemoval(interp, entry.unmatch.matchId);
                    matchRemove(entry.unmatch.matchId);
                }

            } else if (entry.op == RECOLLECT) {
                if (exists(entry.recollect.collectId)) {
                    op("Recollect (s%d:%d) (%s)", entry.recollect.collectId.idx, entry.recollect.collectId.gen, Tcl_GetString(get(entry.recollect.collectId)->clause));
                    recollect(interp, entry.recollect.collectId);
                } else {
                    op("Recollect (s%d:%d) (DEAD)", entry.recollect.collectId.idx, entry.recollect.collectId.gen);
                }
            }
        }
    }
    $cc code {
        void queueInsert(queue_entry_t entry) {
            queue_entry_t* ptr = (queue_entry_t*)ckalloc(sizeof(entry));
            *ptr = entry;
            ptr->seq = seq++;
            pqueue_insert(queue, ptr);
        }
    }
    $cc proc LogWriteAssert {Tcl_Obj* clause} void {
        Tcl_IncrRefCount(clause);
        queueInsert((queue_entry_t) { .op = ASSERT, .assert = {.clause=clause} });
    }
    $cc proc LogWriteRetract {Tcl_Obj* pattern} void {
        Tcl_IncrRefCount(pattern);
        queueInsert((queue_entry_t) { .op = RETRACT, .retract = {.pattern=pattern} });
    }
    $cc proc LogWriteSay {match_handle_t parentMatchId Tcl_Obj* clause} void {
        Tcl_IncrRefCount(clause);
        queueInsert((queue_entry_t) { .op = SAY, .say = {.parentMatchId=parentMatchId, .clause=clause} });
    }
    $cc proc LogWriteUnmatch {match_handle_t matchId} void {
        // TODO: These should probably precede a recollect.
        queueInsert((queue_entry_t) { .op = UNMATCH, .unmatch = {.matchId=matchId} });
    }
    $cc proc LogWriteRecollect {statement_handle_t collectId} void {
        queueInsert((queue_entry_t) { .op = RECOLLECT, .recollect = {.collectId=collectId} });
    }
    $cc proc LogIsEmpty {} bool {
        return pqueue_peek(queue) == NULL;
    }

    $cc compile
    init
}

namespace eval Statements {
    # compatibility with older Tcl statements module interface
    namespace export reactToStatementAddition reactToStatementRemoval
    rename remove_ remove
    rename get getImpl
    proc get {id} { deref [getImpl $id] }
}
namespace eval Matches {
    rename ::Statements::matchExists ::Matches::exists
}
Statements::StatementsInit
Evaluator::EvaluatorInit

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    puts [Statements::addImpl [list whatever dude] 0 [list]]
    puts [Statements::addImpl [list cool dude] 0 [list]]
    puts [Statements::addMatch 2 [list 1 2]]
    puts "matches: [Statements::findStatementsMatching [list /response/ dude]]"
}
