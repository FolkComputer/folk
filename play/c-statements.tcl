# if c-statements.tcl is sourced, it will stomp the old Tcl statement
# implementation
namespace delete statement
namespace delete Statements

namespace eval statement {
    variable cc [c create]
    namespace export $cc

    $cc include <string.h>
    $cc include <stdlib.h>
    $cc include <assert.h>

    $cc struct statement_handle_t { intptr_t idx; }
    $cc struct match_handle_t { int idx; }

    $cc enum edge_type_t { EMPTY, PARENT, CHILD }

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
    # Indirect block that can hold extra edges, if a statement has a
    # lot of match children. This block may get reallocated and resized.
    $cc struct statement_indirect_t {
        size_t capacity_edges;
        edge_to_match_t edges[1]; // should be 0
    }
    $cc struct statement_t {
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
        bool matchHandleIsEqual(match_handle_t a, match_handle_t b) { return a.idx == b.idx; }
        bool statementHandleIsEqual(statement_handle_t a, statement_handle_t b) { return a.idx == b.idx; }

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
                if (edge->type == type &&
                    matchHandleIsEqual(edge->match, matchId)) {
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
    $cc proc matchNew {} match_handle_t {
        while (matches[nextMatchIdx].n_edges != 0) {
            nextMatchIdx = (nextMatchIdx + 1) % (sizeof(matches)/sizeof(matches[0]));
        }
        return (match_handle_t) { .idx = nextMatchIdx };
    }
    $cc proc matchGet {match_handle_t matchId} match_t* {
        return &matches[matchId.idx];
    }
    $cc proc matchDeref {match_t* match} match_t { return *match; }
    $cc proc matchRemove {match_handle_t matchId} void {
        matchGet(matchId)->n_edges = 0;
    }
    $cc proc matchExists {match_handle_t matchId} bool {
        return matchGet(matchId)->n_edges > 0;
    }

    $cc proc new {} statement_handle_t {
        while (statements[nextStatementIdx].clause != NULL) {
            nextStatementIdx = (nextStatementIdx + 1) % (sizeof(statements)/sizeof(statements[0]));
        }
        return (statement_handle_t) { .idx = nextStatementIdx };
    }
    $cc proc get {statement_handle_t id} statement_t* {
        return &statements[id.idx];
    }
    $cc proc deref {statement_t* ptr} statement_t { return *ptr; }
    $cc proc exists {statement_handle_t id} int {
        return get(id)->clause != NULL;
    }
    $cc proc remove_ {statement_handle_t id} void {
        Tcl_Obj* clause = get(id)->clause;
        memset(get(id), 0, sizeof(*get(id)));
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
    $cc proc init {} void {
        statementClauseToId = trieCreate();
    }

    $cc proc addMatchImpl {size_t n_parents statement_handle_t parents[]} match_handle_t {
        // Essentially, allocate a new match object.
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
                      size_t n_parents match_handle_t parents[]} Tcl_Obj* {
        // Is this clause already present among the existing statements?
        void *ids[10];
        int idslen = trieLookup(interp, ids, 10, statementClauseToId, clause);
        statement_handle_t id;
        if (idslen == 1) {
            id.idx = (intptr_t)ids[0];

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

            *get(id) = statementCreate(clause, n_parents, parents, 0, NULL);
            trieAdd(interp, &statementClauseToId, clause, (void *)id.idx);

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

        // return {id, isNewStatement};
        return Tcl_ObjPrintf("{idx %ld} %d", id.idx, isNewStatement);
    }
    proc add {clause {parents {{idx -1} true}}} {
        addImpl $clause [dict size $parents] [dict keys $parents]
    }

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
        void *ids[50];
        int idslen = trieLookup(interp, ids, 50, statementClauseToId, pattern);

        Tcl_Obj* matches[idslen]; int matchcount = 0;
        for (int i = 0; i < idslen; i++) {
            intptr_t id = (intptr_t)ids[i];
            Tcl_Obj* match = unifyImpl(interp, pattern, statements[id].clause);
            if (match != NULL) {
                Tcl_DictObjPut(interp, match, Tcl_ObjPrintf("__matcheeId"), Tcl_ObjPrintf("idx %ld", id));
                matches[matchcount++] = match;
            }
        }

        return Tcl_NewListObj(matchcount, matches);
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

            dict for {matchId _} [statement parentMatchIds $stmt] {
                set matchId [dict get $matchId idx]
                set parents [lmap edge [dict get [matchDeref [matchGet [list idx $matchId]]] edges] {expr {
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
        typedef void (*reaction_fn_t)(statement_handle_t reactingId,
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
            Tcl_ListObjReplace(NULL, reactToPatternAndReactingId, reactToPatternLength-1, 0, 1, &reactingIdObj);
            trieAdd(NULL, &reactionsToStatementAddition, reactToPatternAndReactingId, reaction);

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
            Tcl_EvalObjv(interp, objc, objv, 0);
        }
        static statement_t* get(statement_handle_t id);
        static int exists(statement_handle_t id);
        static Tcl_Obj* unifyImpl(Tcl_Interp* interp, Tcl_Obj* a, Tcl_Obj* b);
        static match_handle_t addMatchImpl(size_t n_parents, statement_handle_t parents[]);
        void reactToStatementAdditionThatMatchesWhen(statement_handle_t whenId,
                                                     Tcl_Obj* whenPattern,
                                                     statement_handle_t statementId) {
            if (!exists(whenId)) {
                removeAllReactions(whenId);
                return;
            }
            statement_t* when = get(whenId);
            statement_t* stmt = get(statementId);

            Tcl_Obj* bindings = unifyImpl(NULL, whenPattern, stmt->clause);
            if (bindings) {
                int whenClauseLength; Tcl_ListObjLength(NULL, when->clause, &whenClauseLength);

                statement_handle_t matchParentIds[] = {whenId, statementId};
                match_handle_t matchId = addMatchImpl(2, matchParentIds);
                Tcl_Obj* body; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-3, &body);
                Tcl_Obj* env; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-1, &env);

                // Merge env into bindings (weakly)
                Tcl_DictSearch search;
                Tcl_Obj *key, *value;
                int done;
                if (Tcl_DictObjFirst(NULL, env, &search,
                                     &key, &value, &done) != TCL_OK) {
                    exit(1);
                }
                for (; !done ; Tcl_DictObjNext(&search, &key, &value, &done)) {
                    Tcl_Obj *existingValue; Tcl_DictObjGet(NULL, bindings, key, &existingValue);
                    if (existingValue == NULL) {
                        Tcl_DictObjPut(NULL, bindings, key, value);
                    }
                }
                Tcl_DictObjDone(&search);

                Tcl_ObjSetVar2(NULL, Tcl_ObjPrintf("matchId"), NULL, Tcl_NewIntObj(matchId.idx), 0);
                tryRunInSerializedEnvironment(NULL, body, bindings);
            }
        }
    }
    $cc proc reactToStatementAddition {Tcl_Interp* interp statement_handle_t id} void {
        Tcl_Obj* clause = get(id)->clause;
        Tcl_Obj* head; Tcl_ListObjIndex(interp, clause, 0, &head);
        if (strcmp(Tcl_GetString(head), "when") == 0) {
            int clauselen; Tcl_ListObjLength(interp, clause, &clauselen);

            // when the time is /t/ { ... } with environment /env/ -> the time is /t/
            Tcl_Obj* pattern = Tcl_DuplicateObj(clause);
            Tcl_ListObjReplace(interp, pattern, clauselen-3, 3, 0, NULL);
            Tcl_ListObjReplace(interp, pattern, 0, 1, 0, NULL);
            addReaction(pattern, id, reactToStatementAdditionThatMatchesWhen);

            // when the time is /t/ { ... } with environment /__env/ -> /someone/ claims the time is /t/
            Tcl_Obj* claimizedPattern = Tcl_DuplicateObj(pattern);
            Tcl_Obj* someoneClaims[] = {Tcl_NewStringObj("/someone/", -1), Tcl_NewStringObj("claims", -1)};
            Tcl_ListObjReplace(interp, claimizedPattern, 0, 0, 2, someoneClaims);
            addReaction(claimizedPattern, id, reactToStatementAdditionThatMatchesWhen);

            // Scan the existing statement set for any
            // already-existing matching statements.
            void* alreadyMatchingStatementIds[50];
            int alreadyMatchingStatementIdsCount = trieLookup(interp, alreadyMatchingStatementIds, 50,
                                                              statementClauseToId, pattern);
            for (int i = 0; i < alreadyMatchingStatementIdsCount; i++) {
                statement_handle_t alreadyMatchingStatementId = {(intptr_t)alreadyMatchingStatementIds[i]};
                reactToStatementAdditionThatMatchesWhen(id, pattern, alreadyMatchingStatementId);
            }
            alreadyMatchingStatementIdsCount = trieLookup(interp, alreadyMatchingStatementIds, 50,
                                                          statementClauseToId, claimizedPattern);
            for (int i = 0; i < alreadyMatchingStatementIdsCount; i++) {
                statement_handle_t alreadyMatchingStatementId = {(intptr_t)alreadyMatchingStatementIds[i]};
                reactToStatementAdditionThatMatchesWhen(id, claimizedPattern, alreadyMatchingStatementId);
            }
        }

        // Trigger any reactions to the addition of this statement.
        Tcl_Obj* clauseWithReactingId = Tcl_DuplicateObj(clause);
        void* reactions[50];
        int reactioncount = trieLookup(interp, reactions, 50,
                                       reactionsToStatementAddition, clauseWithReactingId);
        for (int i = 0; i < reactioncount; i++) {
            reaction_t* reaction = reactions[i];
            reaction->react(reaction->reactingId, reaction->reactToPattern, id);
        }
    }
    $cc proc reactToStatementRemoval {statement_handle_t id} void {
        // unset all things downstream of statement
        statement_t* stmt = get(id);
        for (int i = 0; i < stmt->n_edges; i++) {
            edge_to_match_t* edge = statementEdgeAt(stmt, i);

            if (edge->type != CHILD) continue;
            match_handle_t matchId = edge->match;

            if (!matchExists(matchId)) continue; // if was removed earlier
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
                        reactToStatementRemoval(childId);
                        remove_(childId);
                        matchRemoveEdgeToStatement(match, CHILD, childId);
                    }
                }
            }
            matchRemove(matchId);
        }
    }

    $cc compile
}

namespace eval Statements {
    # compatibility with older Tcl statements module interface
    namespace export reactToStatementAddition reactToStatementRemoval
    rename remove_ remove
    rename findStatementsMatching findMatches
    rename get getImpl
    proc get {id} { deref [getImpl $id] }
}
Statements::init

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    puts [Statements::addImpl [list whatever dude] 0 [list]]
    puts [Statements::addImpl [list cool dude] 0 [list]]
    puts [Statements::addMatch 2 [list 1 2]]
    puts "matches: [Statements::findStatementsMatching [list /response/ dude]]"
}
