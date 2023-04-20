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

    $cc struct statement_handle_t { int32_t idx; int32_t gen; }
    $cc struct match_handle_t { int idx; }

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
        size_t n_edges;
        edge_to_statement_t edges[32];

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
        bool matchHandleIsEqual(match_handle_t a, match_handle_t b) { return a.idx == b.idx; }
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
        // TODO: free destructors
    }
    $cc proc matchExists {match_handle_t matchId} bool {
        return matchGet(matchId)->n_edges > 0;
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
                      size_t n_parents match_handle_t parents[]
                      statement_handle_t* outStatement
                      bool* outIsNewStatement} void {
        // Is this clause already present among the existing statements?
        void *ids[10];
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

            statements[id.idx] = statementCreate(clause, n_parents, parents, 0, NULL);
            statements[id.idx].gen = id.gen;
            trieAdd(interp, &statementClauseToId, clause, *(void **)&id);

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
            statement_handle_t id = *(statement_handle_t *)&ids[i];
            Tcl_Obj* match = unifyImpl(interp, pattern, get(id)->clause);
            if (match != NULL) {
                Tcl_DictObjPut(interp, match, Tcl_ObjPrintf("__matcheeIds"), Tcl_ObjPrintf("{idx %d gen %d}", id.idx, id.gen));
                matches[matchcount++] = match;
            }
        }

        return Tcl_NewListObj(matchcount, matches);
    }
    $cc proc findStatementsMatching_ {Tcl_Interp* interp
                                      int outCount statement_handle_t* outMatches
                                      Tcl_Obj* pattern} int {
        void* ids[outCount];
        int idslen = trieLookup(interp, ids, outCount, statementClauseToId, pattern);

        int matchCount = 0;
        for (int i = 0; i < idslen; i++) {
            statement_handle_t id = *(statement_handle_t *)&ids[i];
            Tcl_Obj* match = unifyImpl(interp, pattern, get(id)->clause);
            if (match != NULL) {
                outMatches[matchCount++] = id;
            }
        }

        return matchCount;
    }
    proc findMatchesJoining {patterns {bindings {}}} {
        if {[llength $patterns] == 0} {
            return [list $bindings]
        }

        # patterns = [list {/p/ is a person} {/p/ lives in /place/}]

        # Split first pattern from the other patterns
        set otherPatterns [lassign $patterns firstPattern]
        # Do substitution of bindings into first pattern
        set substitutedFirstPattern [list]
        foreach word $firstPattern {
            if {[regexp {^/([^/ ]+)/$} $word -> varName] &&
                [dict exists $bindings $varName]} {
                lappend substitutedFirstPattern [dict get $bindings $varName]
            } else {
                lappend substitutedFirstPattern $word
            }
        }

        set matcheeIds [if {[dict exists $bindings __matcheeIds]} {
            dict get $bindings __matcheeIds
        } else { list }]

        set matches [list]
        set matchesForFirstPattern [findMatches $substitutedFirstPattern]
        lappend matchesForFirstPattern {*}[findMatches [list /someone/ claims {*}$substitutedFirstPattern]]
        foreach matchBindings $matchesForFirstPattern {
            dict lappend matchBindings __matcheeIds {*}$matcheeIds
            set matchBindings [dict merge $bindings $matchBindings]
            lappend matches {*}[findMatchesJoining $otherPatterns $matchBindings]
        }
        set matches
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
                if {$matchId == -1} continue
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

    # these are kind of arbitrary/temporary bridge
    $cc proc matchRemoveFirstDestructor {match_handle_t matchId} void {
        Tcl_DecrRefCount(matchGet(matchId)->destructors[0].body);
        Tcl_DecrRefCount(matchGet(matchId)->destructors[0].env);
        matchGet(matchId)->destructors[0].body = NULL;
        matchGet(matchId)->destructors[0].env = NULL;
    }
    $cc proc removeChildMatch {statement_handle_t statementId match_handle_t matchId} void {
        statementRemoveEdgeToMatch(get(statementId), CHILD, matchId);
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
            if (Tcl_EvalObjv(interp, objc, objv, 0) == TCL_ERROR) {
                printf("oh god: %s\n", Tcl_GetString(Tcl_GetObjResult(interp)));
            }
        }
        static statement_t* get(statement_handle_t id);
        static int exists(statement_handle_t id);
        static Tcl_Obj* unifyImpl(Tcl_Interp* interp, Tcl_Obj* a, Tcl_Obj* b);
        static match_handle_t addMatchImpl(size_t n_parents, statement_handle_t parents[]);
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

            Tcl_Obj* bindings = unifyImpl(NULL, whenPattern, stmt->clause);
            if (bindings) {
                int whenClauseLength; Tcl_ListObjLength(NULL, when->clause, &whenClauseLength);

                statement_handle_t matchParentIds[] = {whenId, statementId};
                match_handle_t matchId = addMatchImpl(2, matchParentIds);
                Tcl_Obj* body; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-4, &body);
                Tcl_Obj* env; Tcl_ListObjIndex(NULL, when->clause, whenClauseLength-1, &env);

                // Merge env into bindings (weakly)
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

                Tcl_ObjSetVar2(interp, Tcl_ObjPrintf("::matchId"), NULL, Tcl_ObjPrintf("idx %d", matchId.idx), 0);
                tryRunInSerializedEnvironment(interp, body, bindings);
            }
        }
        void reactToStatementAdditionThatMatchesCollect(Tcl_Interp* interp,
                                                        statement_handle_t collectId,
                                                        Tcl_Obj* collectPattern,
                                                        statement_handle_t statementId) {
            Tcl_EvalObjEx(interp, Tcl_ObjPrintf("lappend Evaluator::log [list Recollect {idx %d gen %d}]", collectId.idx, collectId.gen), 0);
        }
    }
    
    $cc proc EvaluatorInit {} void {
        reactionsToStatementAddition = trieCreate();
    }
    
    # WIP: do recollect in Tcl for now
    if 0 {
    $cc proc recollect {Tcl_Obj* interp statement_handle_t collectId} void {
        // Called when a statement of a pattern that someone is
        // collecting has been added or removed.

        // First, delete the existing match child.
        {
            statement_t* collect = get(collectId);
            match_id_t childMatchId = {0}; // There should be exactly 0 or 1.
            for (size_t i = 0; i < collect->n_edges; i++) {
                if (collect->edges[i].type == CHILD) {
                    childMatchId = collect->edges[i].match;
                    break;
                }
            }
            if (childMatchId.idx != 0) {
                // Delete the first destructor (which would do a
                // recollect) before doing the removal, so the
                // destructor doesn't trigger an infinite cascade of
                // recollects.
                match_t* childMatch = matchGet(childMatchId);
                childMatch->destructors[0] = NULL;

                reactToMatchRemoval(interp, childMatchId);
                matchRemove(childMatchId);
                statementRemoveEdgeToMatch(collect, CHILD, childMatchId);
            }
        }

        Tcl_Obj* clause = collect->clause;
        int clauseLength; Tcl_Obj** clauseWords;
        Tcl_ListObjGetElements(interp, clause, &clauseLength, &clauseWords);
        
        char matchesVarName[100];
        scanVariable(clauseWords[clauseLength-5], matchesVarName, sizeof(matchesVarName));
        Tcl_Obj* env = clauseWords[clauseLength-1];
        
        Tcl_Obj* matches; {
            Tcl_Obj* pattern = clauseWords[5];
            Tcl_Obj* cmd[] = {"Statements::findMatchesJoining", pattern};
            Tcl_EvalObjv(interp, sizeof(cmd)/sizeof(cmd[0]), cmd);
            matches = Tcl_GetObjResult(interp);
        }

        int matchesLength; Tcl_Obj** matchesBindings;
        Tcl_ListObjGetElements(interp, matches, &matchesLength, &matchesBindings);
        statement_handle_t parents[matchesLength];
        size_t n_parents = 0;
        for (int i = 0; i < matchesBindingsLength; i++) {
            Tcl_Obj* matchBindings = matchesBindings[i];
//            parents[n_parents++] =
        }

        addMatchImpl(n_parents, parents);
    }
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
            int patternLength; Tcl_Obj** patternWords;
            Tcl_ListObjGetElements(interp, pattern, &patternLength, &patternWords);
            int subpatternLength = 0;
            for (int i = 0; i <= patternLength; i++) {
                if (i == patternLength ||
                    strcmp(Tcl_GetString(patternWords[i]), "&") == 0) {
                    
                    Tcl_Obj* subpattern = Tcl_NewListObj(subpatternLength, &patternWords[i - subpatternLength]);
                    addReaction(subpattern, id, reactToStatementAdditionThatMatchesCollect);
                    Tcl_Obj* claimizedSubpattern = Tcl_DuplicateObj(subpattern);
                    Tcl_Obj* someoneClaims[] = {Tcl_NewStringObj("/someone/", -1), Tcl_NewStringObj("claims", -1)};
                    Tcl_ListObjReplace(interp, claimizedSubpattern, 0, 0, 2, someoneClaims);
                    addReaction(claimizedSubpattern, id, reactToStatementAdditionThatMatchesCollect);

                    subpatternLength = 0;

                } else {
                    subpatternLength++;
                }
            }

            Tcl_EvalObjEx(interp, Tcl_ObjPrintf("lappend Evaluator::log [list Recollect {idx %d gen %d}]", id.idx, id.gen), 0);

        } else if (strcmp(Tcl_GetString(clauseWords[0]), "when") == 0) {
            // when the time is /t/ { ... } with environment /env/ -> the time is /t/
            Tcl_Obj* pattern = Tcl_DuplicateObj(clause);
            Tcl_ListObjReplace(interp, pattern, clauseLength-4, 4, 0, NULL);
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
                statement_handle_t alreadyMatchingStatementId = *(statement_handle_t *)&alreadyMatchingStatementIds[i];
                reactToStatementAdditionThatMatchesWhen(interp, id, pattern, alreadyMatchingStatementId);
            }
            alreadyMatchingStatementIdsCount = trieLookup(interp, alreadyMatchingStatementIds, 50,
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
        void* reactions[50];
        int reactioncount = trieLookup(interp, reactions, 50,
                                       reactionsToStatementAddition, clauseWithReactingIdWildcard);
        for (int i = 0; i < reactioncount; i++) {
            reaction_t* reaction = reactions[i];
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
        statement_t* stmt = get(id);
        for (int i = 0; i < stmt->n_edges; i++) {
            edge_to_match_t* edge = statementEdgeAt(stmt, i);

            if (edge->type != CHILD) continue;
            match_handle_t matchId = edge->match;

            if (!matchExists(matchId)) continue; // if was removed earlier

            reactToMatchRemoval(interp, matchId);
            matchRemove(matchId);
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
        int evaluatorLogReadIndex = 0;
        int evaluatorLogWriteIndex = 0;
    }
    $cc proc Evaluate {Tcl_Interp* interp} void {
        while (evaluatorLogReadIndex != evaluatorLogWriteIndex) {
            log_entry_t entry = evaluatorLog[evaluatorLogReadIndex];
            evaluatorLogReadIndex = (evaluatorLogReadIndex + 1) % (sizeof(evaluatorLog)/sizeof(evaluatorLog[0]));
            
            if (entry.op == ASSERT) {
                statement_handle_t id; bool isNewStatement;
                addImpl(interp, entry.assert.clause, 0, NULL,
                        &id, &isNewStatement);
                if (isNewStatement) {
                    reactToStatementAddition(interp, id);
                }

            } else if (entry.op == RETRACT) {
                statement_handle_t matches[50];
                int matchCount = findStatementsMatching_(interp, 50, matches, entry.retract.pattern);
                for (int i = 0; i < matchCount; i++) {
                    statement_handle_t id = matches[i];
                    reactToStatementRemoval(interp, id);
                    remove_(id);
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
                
            }
        }
    }
    $cc code {
        void LogWrite(log_entry_t entry) {
            evaluatorLogWriteIndex = (evaluatorLogWriteIndex + 1) % (sizeof(evaluatorLog)/sizeof(evaluatorLog[0]));
            if (evaluatorLogWriteIndex == evaluatorLogReadIndex) { exit(100); }

            evaluatorLog[evaluatorLogWriteIndex] = entry;
        }
    }
    $cc proc LogWriteAssert {Tcl_Obj* clause} void {
        Tcl_IncrRefCount(clause);
        LogWrite((log_entry_t) { .op = ASSERT, .assert = {.clause=clause} });
    }
    $cc proc LogWriteRetract {Tcl_Obj* pattern} void {
        Tcl_IncrRefCount(pattern);
        LogWrite((log_entry_t) { .op = RETRACT, .retract = {.pattern=pattern} });
    }
    $cc proc LogWriteSay {match_handle_t parentMatchId Tcl_Obj* clause} void {
        Tcl_IncrRefCount(clause);
        LogWrite((log_entry_t) { .op = SAY, .say = {.parentMatchId=parentMatchId, .clause=clause} });
    }
    $cc proc LogWriteRecollect {statement_handle_t collectId} void {
        LogWrite((log_entry_t) { .op = RECOLLECT, .recollect = {.collectId=collectId} });
    }

    rename Evaluator::reactToStatementAddition ""
    rename Evaluator::reactToStatementRemoval ""

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
namespace eval Matches {
    rename exists ""
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
