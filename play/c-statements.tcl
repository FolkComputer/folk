namespace eval statement {
    variable cc [c create]
    namespace export $cc

    $cc include <string.h>
    $cc include <stdlib.h>
    $cc include <assert.h>

    $cc struct statement_handle_t { int32_t idx; int32_t gen; }
    $cc struct match_handle_t { int32_t idx; int32_t gen; }

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

        size_t n_edges;
        edge_to_statement_t edges[64];

        bool recollectOnDestruction;
        statement_handle_t recollectCollectId;

        match_destructor_t destructors[8];
    }

    $cc struct edge_to_match_t {
        edge_type_t type;
        match_handle_t match;
    }
    # Indirect block that can hold extra edges, if a statement has a
    # lot of match children. This block may get reallocated and resized.
    $cc struct statement_indirect_t {
        size_t capacity_edges;
        edge_to_match_t edges[1]; // should be 0
    }
    $cc struct statement_t {
        int32_t gen;

        Tcl_Obj* clause;

        size_t n_edges;
        edge_to_match_t edges[16];

        statement_indirect_t* indirect;
    }

    $cc include <stdbool.h>
    $cc code {
        statement_t statementCreate(Tcl_Obj* clause,
                                    size_t n_parents, match_handle_t parents[],
                                    size_t n_children, match_handle_t children[]) {
            statement_t ret = {0};
            ret.clause = clause; Tcl_IncrRefCount(clause);
            // FIXME: Use edge helpers.
            assert(n_parents + n_children < sizeof(ret.edges)/sizeof(ret.edges[0]));
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
            return i < sizeof(stmt->edges)/sizeof(stmt->edges[0]) ?
                &stmt->edges[i] :
                &stmt->indirect->edges[i - sizeof(stmt->edges)/sizeof(stmt->edges[0])];
        }
        // Given stmt, moves all non-EMPTY edges to the front of the
        // statement's edgelist, then updates stmt->n_edges
        // accordingly.
        //
        // Defragmentation is necessary to prevent continual growth of
        // the statement edgelist if you keep adding and removing
        // edges on the same statement.
        static void statementDefragmentEdges(statement_t* stmt) {
            // Copy all non-EMPTY edges into a temporary edgelist.
            size_t n_edges = 0;
            edge_to_match_t edges[stmt->n_edges];
            for (size_t i = 0; i < stmt->n_edges; i++) {
                edge_to_match_t* edge = statementEdgeAt(stmt, i);
                if (edge->type != EMPTY) { edges[n_edges++] = *edge; }
            }

            // Copy edges back from the temporary edgelist.
            for (size_t i = 0; i < n_edges; i++) {
                *statementEdgeAt(stmt, i) = edges[i];
            }
            stmt->n_edges = n_edges;
        }
        void statementAddEdgeToMatch(statement_t* stmt,
                                     edge_type_t type, match_handle_t matchId) {
            edge_to_match_t edge = (edge_to_match_t) { .type = type, .match = matchId };

            if (stmt->n_edges < sizeof(stmt->edges)/sizeof(stmt->edges[0])) {
                // There's at least one free slot among the direct
                // edge slots in the statement itself.
                stmt->edges[stmt->n_edges++] = edge;
                return;
            }

            if (stmt->n_edges == sizeof(stmt->edges)/sizeof(stmt->edges[0]) &&
                stmt->indirect == NULL) {
                // We've run out of edge slots in the
                // statement. Allocate an indirect block with more
                // slots.
                size_t capacity_edges = sizeof(stmt->edges)/sizeof(stmt->edges[0]);
                statement_indirect_t* indirect = ckalloc(sizeof(statement_indirect_t) + capacity_edges*sizeof(edge_to_match_t));
                memset(indirect, 0, sizeof(statement_indirect_t) + capacity_edges*sizeof(edge_to_match_t));
                indirect->capacity_edges = capacity_edges;

                stmt->indirect = indirect;

                statementDefragmentEdges(stmt);

                // Start again from the top with the defragmented state.
                statementAddEdgeToMatch(stmt, type, matchId);
                return;
            }

            // Seems like we'll have to store the edge in the indirect block.
            assert(stmt->indirect != NULL);

            if (stmt->n_edges == sizeof(stmt->edges)/sizeof(stmt->edges[0]) + stmt->indirect->capacity_edges) {
                // We've run out of edge pointer slots in the current
                // indirect block; we need to grow the indirect block.
                size_t new_capacity_edges = stmt->indirect->capacity_edges*2;
                // printf("Growing indirect for %p (%zu -> %zu)\n", stmt,
                //       stmt->indirect->capacity_edges, new_capacity_edges);

                stmt->indirect = ckrealloc(stmt->indirect,
                                           sizeof(*stmt->indirect) + new_capacity_edges*sizeof(edge_to_match_t));
                memset(stmt->indirect, 0, sizeof(statement_indirect_t) + stmt->indirect->capacity_edges*sizeof(edge_to_match_t));
                stmt->indirect->capacity_edges = new_capacity_edges;

                statementDefragmentEdges(stmt);

                // Start again from the top with the defragmented state.
                statementAddEdgeToMatch(stmt, type, matchId);
                return;
            }

            size_t edgeIdx = stmt->n_edges++;
            size_t edgeIdxInIndirect = edgeIdx - sizeof(stmt->edges)/sizeof(stmt->edges[0]);
            // There should be room for the new edge in the indirect block.
            assert(edgeIdxInIndirect < stmt->indirect->capacity_edges);
            // Store the edge in the indirect block.
            stmt->indirect->edges[edgeIdxInIndirect] = edge;
        }
        int statementRemoveEdgeToMatch(statement_t* stmt,
                                       edge_type_t type, match_handle_t matchId) {
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
        void matchAddEdgeToStatement(match_t* match,
                                     edge_type_t type, statement_handle_t statementId) {
            size_t edgeIdx = match->n_edges++;
            assert(edgeIdx < sizeof(match->edges)/sizeof(match->edges[0]));
            match->edges[edgeIdx] = (edge_to_statement_t) { .type = type, .statement = statementId };
        }
        void matchRemoveEdgeToStatement(match_t* match,
                                        edge_type_t type, statement_handle_t statementId) {
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

    namespace export clause parentMatchIds childMatchIds
    $cc proc clause {Tcl_Obj* stmtobj} Tcl_Obj* {
        assert(stmtobj->typePtr == &statement_t_ObjType);
        return ((statement_t *)stmtobj->internalRep.otherValuePtr)->clause;
    }
    $cc proc edges {Tcl_Interp* interp Tcl_Obj* stmtobj} Tcl_Obj* {
        assert(stmtobj->typePtr == &statement_t_ObjType);
        statement_t* stmt = stmtobj->internalRep.otherValuePtr;
        Tcl_Obj* ret = Tcl_NewListObj(stmt->n_edges, NULL);
        for (size_t i = 0; i < stmt->n_edges; i++) {
            edge_to_match_t* edge = statementEdgeAt(stmt, i);
            Tcl_Obj* edgeobj = Tcl_NewObj();
            edgeobj->typePtr = &edge_to_match_t_ObjType;
            edgeobj->bytes = NULL;
            edgeobj->internalRep.otherValuePtr = edge;
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
    $cc proc claimizePattern {Tcl_Obj* pattern} Tcl_Obj* {
        // the time is /t/ -> /someone/ claims the time is /t/
        Tcl_Obj* ret = Tcl_DuplicateObj(pattern);
        Tcl_Obj* someoneClaims[] = {Tcl_NewStringObj("/someone/", -1), Tcl_NewStringObj("claims", -1)};
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
        while (matches[nextMatchIdx].alive) {
            nextMatchIdx = (nextMatchIdx + 1) % (sizeof(matches)/sizeof(matches[0]));
        }
        matches[nextMatchIdx].alive = true;
        matches[nextMatchIdx].n_edges = 0;
        return (match_handle_t) {
            .idx = nextMatchIdx,
            .gen = ++matches[nextMatchIdx].gen
        };
    }
    $cc proc matchGet {match_handle_t matchId} match_t* {
        if (matchId.gen != matches[matchId.idx].gen || !matches[matchId.idx].alive) {
            return NULL;
        }
        return &matches[matchId.idx];
    }
    $cc proc matchDeref {match_t* match} match_t { return *match; }
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
        if (match->recollectOnDestruction) {
            LogWriteRecollect(match->recollectCollectId);
        }
        match->alive = false;
        match->n_edges = 0;
    }
    $cc proc matchExists {match_handle_t matchId} bool {
        return matchGet(matchId)->alive;
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
            .gen = ++statements[nextStatementIdx].gen
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
        memset(stmt, 0, sizeof(*stmt));
        stmt->gen = gen;
        trieRemove(NULL, statementClauseToId, clause);
        Tcl_DecrRefCount(clause);
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
    $cc import ::ctrie::cc add as trieAdd
    $cc import ::ctrie::cc remove_ as trieRemove
    $cc import ::ctrie::cc scanVariable as scanVariable
    $cc proc StatementsInit {} void {
        statementClauseToId = trieCreate();
    }

    $cc proc addMatchImpl {size_t n_parents statement_handle_t parents[]} match_handle_t {
        match_handle_t matchId = matchNew();
        match_t* match = matchGet(matchId);

        for (int i = 0; i < n_parents; i++) {
            matchAddEdgeToStatement(match, PARENT, parents[i]);
            statementAddEdgeToMatch(get(parents[i]), CHILD, matchId);
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
        int idslen = trieLookup(interp, ids, 10, statementClauseToId, clause);
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
            statement_t* stmt = get(id);
            for (size_t i = 0; i < n_parents; i++) {
                statementAddEdgeToMatch(stmt, PARENT, parents[i]);
            }
        }

        for (size_t i = 0; i < n_parents; i++) {
            if (parents[i].idx == -1) { continue; } // ?

            match_t* match = matchGet(parents[i]);
            matchAddEdgeToStatement(match, CHILD, id);
        }

        *outStatement = id;
        *outIsNewStatement = isNewStatement;
    }
    proc add {clause {parents {{idx -1} true}}} {
        addImpl $clause [dict size $parents] [dict keys $parents]
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
    $cc proc unify {Tcl_Obj* a Tcl_Obj* b} environment_t* {
        int alen; Tcl_Obj** awords;
        int blen; Tcl_Obj** bwords;
        Tcl_ListObjGetElements(NULL, a, &alen, &awords);
        Tcl_ListObjGetElements(NULL, b, &blen, &bwords);
        if (alen != blen) { return NULL; }

        environment_t* env = ckalloc(sizeof(environment_t) + sizeof(environment_binding_t)*alen);
        memset(env, 0, sizeof(*env));
        for (int i = 0; i < alen; i++) {
            char aVarName[100] = {0}; char bVarName[100] = {0};
            if (scanVariable(awords[i], aVarName, sizeof(aVarName))) {
                environment_binding_t* binding = &env->bindings[env->bindingsCount++];
                memcpy(binding->name, aVarName, sizeof(binding->name));
                binding->value = bwords[i];
            } else if (scanVariable(bwords[i], bVarName, sizeof(bVarName))) {
                environment_binding_t* binding = &env->bindings[env->bindingsCount++];
                memcpy(binding->name, bVarName, sizeof(binding->name));
                binding->value = awords[i];
            } else if (!(awords[i] == bwords[i] ||
                         strcmp(Tcl_GetString(awords[i]), Tcl_GetString(bwords[i])) == 0)) {
                ckfree(env);
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
            Tcl_DictObjPut(NULL, matchObj, Tcl_ObjPrintf("__matcheeIds"), Tcl_ObjPrintf("{idx %d gen %d}", id.idx, id.gen));
            Tcl_ListObjAppendElement(NULL, ret, matchObj);
            ckfree(results[i]);
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
        if (patternsCount == 0) {
            outResults[(*outResultsCount)++] = env;
            return;
        }

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
        resultsForFirstPatternCount += searchByPattern(claimizePattern(substitutedFirstPattern),
                                                       maxResultsCount - resultsForFirstPatternCount, &resultsForFirstPattern[resultsForFirstPatternCount]);
            
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
            searchByPatterns(patternsCount - 1, &patterns[1],
                             result,
                             maxResultsCount - 1, outResults,
                             outResultsCount);
        }
    }
    $cc proc findMatchesJoining {Tcl_Obj* patterns Tcl_Obj* bindings} Tcl_Obj* {
        environment_t* results[1000];
        int patternsCount; Tcl_Obj** patternsObjs;
        Tcl_ListObjGetElements(NULL, patterns, &patternsCount, &patternsObjs);
        int resultsCount = 0;

        environment_t* env = ckalloc(sizeof(environment_t) + 10*sizeof(environment_binding_t));
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

        Tcl_Obj* ret = Tcl_NewListObj(0, NULL);
        for (int i = 0; i < resultsCount; i++) {
            // TODO: Emit __matcheeIds properly based on results[i]
            Tcl_ListObjAppendElement(NULL, ret, environmentToTclDict(results[i]));
            ckfree(results[i]);
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
            s->internalRep.otherValuePtr = &statements[i];

            Tcl_ListObjAppendElement(NULL, ret, Tcl_ObjPrintf("idx %d", i));
            Tcl_ListObjAppendElement(NULL, ret, s);
        }
        return ret;
    }
    proc dot {} {
        set dot [list]
        dict for {id stmt} [all] {
            set id [dict get $id idx]

            lappend dot "subgraph cluster_$id {"
            lappend dot "color=lightgray;"

            set label [statement clause $stmt]
            set label [join [lmap line [split $label "\n"] {
                expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
            }] "\n"]
            set label [string map {"\"" "\\\""} [string map {"\\" "\\\\"} $label]]
            lappend dot "s$id \[label=\"s$id: $label\"\];"

            dict for {matchId_ _} [statement parentMatchIds $stmt] {
                set matchId [dict get $matchId_ idx]
                if {$matchId == -1} continue
                set parents [lmap edge [dict get [matchDeref [matchGet $matchId_]] edges] {expr {
                    [dict get $edge type] == 1 ? "s[dict get $edge statement idx]" : [continue]
                }}]
                lappend dot "m$matchId \[label=\"m$matchId <- $parents\"\];"
                lappend dot "m$matchId -> s$id;"
            }

            lappend dot "}"

            dict for {childId _} [statement childMatchIds $stmt] {
                set childId [dict get $childId idx]
                lappend dot "s$id -> m$childId;"
            }
        }
        return "digraph { rankdir=LR; [join $dot "\n"] }"
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
            reaction_t *reaction = ckalloc(sizeof(reaction_t));
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
            // TODO: list walk
            int patternCount; Tcl_Obj** patterns;
            Tcl_ListObjGetElements(NULL, reactionPatternsOfReactingId[reactingId.idx],
                                   &patternCount, &patterns);
            for (int i = 0; i < patternCount; i++) {
                trieRemove(NULL, reactionsToStatementAddition, patterns[i]);
            }
            Tcl_DecrRefCount(reactionPatternsOfReactingId[reactingId.idx]);
            reactionPatternsOfReactingId[reactingId.idx] = NULL;
        }

        void tryRunInSerializedEnvironment(Tcl_Interp* interp, Tcl_Obj* body, Tcl_Obj* env) {
            int objc = 3; Tcl_Obj *objv[3];
            objv[0] = Tcl_NewStringObj("Evaluator::tryRunInSerializedEnvironment", -1);
            objv[1] = body;
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
                Tcl_Obj* body; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-4, &body);
                Tcl_Obj* env; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-1, &env);

                // Merge env into bindings (weakly)
                Tcl_Obj *bindings = environmentToTclDict(result);
                Tcl_DictSearch search;
                Tcl_Obj *key, *value;
                int done;
                if (Tcl_DictObjFirst(NULL, env, &search,
                                     &key, &value, &done) != TCL_OK) {
                    printf("Reacting %d(%s) to addition of (%s): env is weird (%s)\n",
                           whenId.idx,
                           Tcl_GetString(when->clause),
                           Tcl_GetString(stmt->clause),
                           Tcl_GetString(env));
                    exit(2);
                }
                for (; !done ; Tcl_DictObjNext(&search, &key, &value, &done)) {
                    Tcl_Obj *existingValue; Tcl_DictObjGet(NULL, bindings, key, &existingValue);
                    if (existingValue == NULL) {
                        Tcl_DictObjPut(NULL, bindings, key, value);
                    }
                }
                Tcl_DictObjDone(&search);

                Tcl_ObjSetVar2(interp, Tcl_ObjPrintf("::matchId"), NULL, Tcl_ObjPrintf("idx %d gen %d", matchId.idx, matchId.gen), 0);
                tryRunInSerializedEnvironment(interp, body, bindings);
            }
        }
        static void LogWriteRecollect(statement_handle_t collectId);
        void reactToStatementAdditionThatMatchesCollect(Tcl_Interp* interp,
                                                        statement_handle_t collectId,
                                                        Tcl_Obj* collectPattern,
                                                        statement_handle_t statementId) {
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
        // printf("React to %s: %d\n", Tcl_GetString(clauseWithReactingIdWildcard), reactionCount);
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

                statementRemoveEdgeToMatch(get(parentId), CHILD, matchId);

            } else if (match->edges[j].type == CHILD) {
                statement_handle_t childId = match->edges[j].statement;
                if (!exists(childId)) { continue; }

                if (statementRemoveEdgeToMatch(get(childId), PARENT, matchId) == 0) {
                    // is this child statement out of parent matches? => it's dead
                    reactToStatementRemoval(interp, childId);
                    remove_(childId);
                    matchRemoveEdgeToStatement(match, CHILD, childId);
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

                matchRemoveEdgeToStatement(matchGet(matchId), CHILD, id);

            } else if (edge->type == CHILD) {
                match_handle_t matchId = edge->match;
                if (!matchExists(matchId)) continue; // if was removed earlier

                reactToMatchRemoval(interp, matchId);
                matchRemove(matchId);
            }
        }
    }
    $cc proc UnmatchImpl {Tcl_Interp* interp match_handle_t currentMatchId int level} void {
        match_handle_t unmatchId = currentMatchId;
        for (int i = 0; i < level; i++) {
            match_t* unmatch = matchGet(unmatchId);
            // Get first parent of unmatchId (should be the When)
            statement_handle_t unmatchWhenId = {0};
            for (int j = 0; j < unmatch->n_edges; j++) {
                if (unmatch->edges[j].type == PARENT) {
                    unmatchWhenId = unmatch->edges[j].statement;
                    break;
                }
            }
            if (unmatchWhenId.idx == 0) { exit(3); }
            statement_t* unmatchWhen = get(unmatchWhenId);
            for (int j = 0; j < unmatchWhen->n_edges; j++) {
                if (unmatchWhen->edges[j].type == PARENT) {
                    unmatchId = unmatchWhen->edges[j].match;
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

        // First, delete the existing match child.
        {
            for (size_t i = 0; i < collect->n_edges; i++) {
                edge_to_match_t* edge = statementEdgeAt(collect, i);
                if (edge->type == CHILD) {
                    match_handle_t childMatchId = edge->match;
                    matchGet(childMatchId)->recollectOnDestruction = false;
                    reactToMatchRemoval(interp, childMatchId);
                    matchRemove(childMatchId);
                    break;
                }
            }
        }

        Tcl_Obj* clause = collect->clause;
        int clauseLength; Tcl_Obj** clauseWords;
        Tcl_ListObjGetElements(interp, clause, &clauseLength, &clauseWords);

        Tcl_Obj* body = clauseWords[clauseLength-4];
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
        }

        match_handle_t matchId = addMatchImpl(parentsCount, parents);
        match_t* match = matchGet(matchId);
        match->recollectOnDestruction = true;
        match->recollectCollectId = collectId;

        /* environment_binding_t* matchesVarBinding = env->bindings[env->bindingsCount++]; */
        /* memcpy(matchesVarBinding->name, matchesVarName, 100); */
        /* matchesVarBinding->value = matches; */
        env = Tcl_DuplicateObj(env);
        Tcl_DictObjPut(NULL, env, Tcl_NewStringObj(matchesVarName, -1), matches);
        Tcl_ObjSetVar2(interp, Tcl_ObjPrintf("::matchId"), NULL, Tcl_ObjPrintf("idx %d gen %d", matchId.idx, matchId.gen), 0);
        tryRunInSerializedEnvironment(interp, body, env);
    }

    $cc code {
        typedef enum {
            NONE, ASSERT, RETRACT, SAY, RECOLLECT
        } log_entry_op_t;
        typedef struct log_entry_t {
            log_entry_op_t op;
            union {
                struct { Tcl_Obj* clause; } assert;
                struct { Tcl_Obj* pattern; } retract;
                struct {
                    match_handle_t parentMatchId;
                    Tcl_Obj* clause;
                } say;
                struct { statement_handle_t collectId; } recollect;
            };
        } log_entry_t;

        log_entry_t evaluatorLog[1024] = {0};
        #define EVALUATOR_LOG_CAPACITY (sizeof(evaluatorLog)/sizeof(evaluatorLog[1]))
        int evaluatorLogReadIndex = EVALUATOR_LOG_CAPACITY - 1;
        int evaluatorLogWriteIndex = 0;
    }
    $cc proc Evaluate {Tcl_Interp* interp} void {
        while (evaluatorLogReadIndex != evaluatorLogWriteIndex) {
            log_entry_t entry = evaluatorLog[evaluatorLogReadIndex];
            evaluatorLogReadIndex = (evaluatorLogReadIndex + 1) % EVALUATOR_LOG_CAPACITY;

            if (entry.op == ASSERT) {
                statement_handle_t id; bool isNewStatement;
                addImpl(interp, entry.assert.clause, 0, NULL,
                        &id, &isNewStatement);
                if (isNewStatement) {
                    reactToStatementAddition(interp, id);
                }

            } else if (entry.op == RETRACT) {
                environment_t* results[1000];
                int resultsCount = searchByPattern(entry.retract.pattern,
                                                   1000, results);
                for (int i = 0; i < resultsCount; i++) {
                    statement_handle_t id = results[i]->matchedStatementIds[0];
                    reactToStatementRemoval(interp, id);
                    remove_(id);
                    ckfree(results[i]);
                }

            } else if (entry.op == SAY) {
                if (matchExists(entry.say.parentMatchId)) {
                    statement_handle_t id; bool isNewStatement;
                    addImpl(interp, entry.say.clause, 1, &entry.say.parentMatchId,
                            &id, &isNewStatement);
                    if (isNewStatement) {
                        reactToStatementAddition(interp, id);
                    }
                }

            } else if (entry.op == RECOLLECT) {
                if (exists(entry.recollect.collectId)) {
                    recollect(interp, entry.recollect.collectId);
                }
            }
        }
    }
    $cc code {
        void LogWriteFront(log_entry_t entry) {
            if ((evaluatorLogReadIndex - 1) % EVALUATOR_LOG_CAPACITY == evaluatorLogWriteIndex) { exit(100); }
            evaluatorLogReadIndex = (evaluatorLogReadIndex - 1) % EVALUATOR_LOG_CAPACITY;
            evaluatorLog[evaluatorLogReadIndex] = entry;
        }
        void LogWriteBack(log_entry_t entry) {
            if ((evaluatorLogWriteIndex + 1) % EVALUATOR_LOG_CAPACITY == evaluatorLogReadIndex) { exit(100); }
            evaluatorLog[evaluatorLogWriteIndex] = entry;
            evaluatorLogWriteIndex = (evaluatorLogWriteIndex + 1) % EVALUATOR_LOG_CAPACITY;
        }
    }
    $cc proc LogWriteAssert {Tcl_Obj* clause} void {
        Tcl_IncrRefCount(clause);
        LogWriteBack((log_entry_t) { .op = ASSERT, .assert = {.clause=clause} });
    }
    $cc proc LogWriteRetract {Tcl_Obj* pattern} void {
        Tcl_IncrRefCount(pattern);
        LogWriteBack((log_entry_t) { .op = RETRACT, .retract = {.pattern=pattern} });
    }
    $cc proc LogWriteSay {match_handle_t parentMatchId Tcl_Obj* clause} void {
        Tcl_IncrRefCount(clause);
        LogWriteFront((log_entry_t) { .op = SAY, .say = {.parentMatchId=parentMatchId, .clause=clause} });
    }
    $cc proc LogWriteRecollect {statement_handle_t collectId} void {
        LogWriteBack((log_entry_t) { .op = RECOLLECT, .recollect = {.collectId=collectId} });
    }

    $cc compile
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
