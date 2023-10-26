# trie.tcl --
#
#     Implements the statement trie datatype and operations. This data
#     structure has 2 differences from the average trie you might have
#     seen before.
#
#     1. Its nodes are _entire tokens_, not characters.
#
#        someone -> wishes -> 30 -> is -> labelled -> Hello World
#
#        not
#
#        s -> o -> m -> e -> o -> n -> e -> SPACE -> w -> i -> ...
#
#        In other words, its alphabet is dynamic -- the set of all
#        tokens that programs are using in statements -- not 26
#        characters or whatever.
#
#     2. Both search patterns and nodes can contain 'wildcards'.
#
#        This bidirectional matching is useful for incremental update.
#

namespace eval ctrie {
    variable cc [c create]
    $cc include <stdlib.h>
    $cc include <string.h>
    $cc include <stdbool.h>
    $cc code {
        typedef struct trie_t trie_t;
        struct trie_t {
            Jim_Obj* key;

            // We generally store a pointer (for example, to a
            // reaction thunk) or a generational handle (for example,
            // for a statement) in this 64-bit value slot.
            bool hasValue;
            uint64_t value;

            size_t nbranches;
            trie_t* branches[];
        };
    }

    $cc proc create {} trie_t* {
        size_t size = sizeof(trie_t) + 10*sizeof(trie_t*);
        trie_t* ret = (trie_t *) malloc(size); memset(ret, 0, size);
        *ret = (trie_t) {
            .key = NULL,
            .hasValue = false,
            .value = 0,
            .nbranches = 10
        };
        return ret;
    }

    $cc proc scanVariable {Jim_Obj* wordobj char* outVarName size_t sizeOutVarName} int {
        const char* word; int wordlen; word = Jim_GetString(wordobj, &wordlen);
        if (wordlen < 3 || (outVarName && wordlen >= sizeOutVarName)) { return false; }
        if (!(word[0] == '/' && word[wordlen - 1] == '/')) { return false; }
        int i;
        for (i = 1; i < wordlen - 1; i++) {
            if (word[i] == '/' || word[i] == ' ') { return false; }
            if (outVarName) outVarName[i - 1] = word[i];
        }
        if (outVarName) outVarName[i - 1] = '\0';
        return true;
    }
    # These functions operate on the Jim string representation of a
    # value _without_ coercing the value into a pure string first, so
    # they avoid shimmering / are more efficient than using Jim
    # builtin functions like `regexp` and `string index`.
    $cc proc scanVariable_ {Jim_Obj* wordobj} Jim_Obj* {
        char varName[100];
        if (scanVariable(wordobj, varName, 100) == false) {
            return Jim_NewStringObj(interp, "false", -1);            
        }
        return Jim_NewStringObj(interp, varName, -1);
    }
    $cc proc startsWithDollarSign {Jim_Obj* wordobj} bool {
        return Jim_String(wordobj)[0] == '\$';
    }

    $cc proc addImpl {trie_t** trie Jim_Obj* clause int clauseidx uint64_t value} void {
        int wordc = Jim_ListLength(interp, clause) - clauseidx;
        if (wordc == 0) {
            (*trie)->value = value;
            (*trie)->hasValue = true;
            return;
        }

        Jim_Obj* word = Jim_ListGetIndex(interp, clause, clauseidx);

        trie_t** match = NULL;

        int j;
        for (j = 0; j < (*trie)->nbranches; j++) {
            trie_t** branch = &(*trie)->branches[j];
            if (*branch == NULL) { break; }

            if ((*branch)->key == word ||
                strcmp(Jim_String((*branch)->key), Jim_String(word)) == 0) {

                match = branch;
                break;
            }
        }

        if (match == NULL) { // add new branch
            if (j == (*trie)->nbranches) {
                // we're out of room, need to grow trie
                (*trie)->nbranches *= 2;
                *trie = (trie_t *) realloc((char *) *trie, sizeof(trie_t) + (*trie)->nbranches*sizeof(trie_t*));
                memset(&(*trie)->branches[j], 0, ((*trie)->nbranches/2)*sizeof(trie_t*));
            }

            size_t size = sizeof(trie_t) + 10*sizeof(trie_t*);
            trie_t* branch = (trie_t *) malloc(size); memset(branch, 0, size);
            branch->key = word;
            Jim_IncrRefCount(branch->key);
            branch->value = 0;
            branch->hasValue = false;
            branch->nbranches = 10;

            (*trie)->branches[j] = branch;
            match = &(*trie)->branches[j];
        }

        addImpl(match, clause, clauseidx + 1, value);
    }
    $cc proc add {Jim_Interp* interp trie_t** trie Jim_Obj* clause uint64_t value} void {
        addImpl(trie, clause, 0, value);
    }
    $cc proc addWithVar {Jim_Interp* interp Jim_Obj* trieVar Jim_Obj* clause uint64_t value} void {
        trie_t* trie; sscanf(Jim_String(Jim_GetVariable(interp, trieVar, 0)), "(trie_t*) 0x%p", &trie);
        add(interp, &trie, clause, value);
        Jim_SetVariable(interp, trieVar, Jim_ObjPrintf(interp, "(trie_t*) 0x%" PRIxPTR, (uintptr_t) trie));
    }

    $cc proc removeImpl {trie_t* trie Jim_Obj* clause int clauseidx} int {
        int wordc = Jim_ListLength(interp, clause) - clauseidx;
        if (wordc == 0) return 1;
        Jim_Obj* word = Jim_ListGetIndex(interp, clause, clauseidx);

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }
            if (trie->branches[j]->key == word ||
                strcmp(Jim_String(trie->branches[j]->key), Jim_String(word)) == 0) {
                if (removeImpl(trie->branches[j], clause, clauseidx + 1)) {
                    Jim_DecrRefCount(interp, trie->branches[j]->key);
                    free((char *) trie->branches[j]);
                    trie->branches[j] = NULL;
                    if (j == 0 && trie->branches[1] == NULL) {
                        return 1;
                    } else if (trie->branches[j + 1] != NULL) {
                        // shift left
                        memcpy(&trie->branches[j], &trie->branches[j + 1], (trie->nbranches - j - 1) * sizeof(trie->branches[0]));
                        trie->branches[trie->nbranches - 1] = NULL;
                        return 0;
                    }
                }
            }
        }
        return 0;
    }
    $cc proc remove_ {Jim_Interp* interp trie_t* trie Jim_Obj* clause} void {
        removeImpl(trie, clause, 0);
    }
    $cc proc removeWithVar {Jim_Interp* interp Jim_Obj* trieVar Jim_Obj* clause} void {
        trie_t* trie; sscanf(Jim_String(Jim_GetVariable(interp, trieVar, 0)), "(trie_t*) 0x%p", &trie);
        remove_(interp, trie, clause);
    }

    $cc proc lookupAll {uint64_t* results int* resultsidx size_t maxresults
                        trie_t* trie} void {
        if (trie->hasValue) {
            if (*resultsidx < maxresults) {
                results[(*resultsidx)++] = trie->value;
            }
        }
        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }
            lookupAll(results, resultsidx, maxresults, trie->branches[j]);
        }
    }

    # Given a clause `clause` subsequence starting at `clauseidx`,
    # looks for all matches in the trie `trie`.
    $cc proc lookupImpl {Jim_Interp* interp
                         uint64_t* results int* resultsidx size_t maxresults
                         trie_t* trie Jim_Obj* clause int clauseidx} void {
        int wordc = Jim_ListLength(interp, clause) - clauseidx;
        if (wordc == 0) {
            if (trie->hasValue) {
                if (*resultsidx < maxresults) {
                    results[(*resultsidx)++] = trie->value;
                }
            }
            return;
        }

        Jim_Obj* word = Jim_ListGetIndex(interp, clause, clauseidx);
        enum { WORD_TYPE_LITERAL, WORD_TYPE_VARIABLE, WORD_TYPE_REST_VARIABLE } wordType;
        char wordVarName[100];
        if (scanVariable(word, wordVarName, 100)) {
            if (wordVarName[0] == '.' && wordVarName[1] == '.' && wordVarName[2] == '.') {
                wordType = WORD_TYPE_REST_VARIABLE;
            } else { wordType = WORD_TYPE_VARIABLE; }
        } else { wordType = WORD_TYPE_LITERAL; }

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }

            // Easy cases:
            if (trie->branches[j]->key == word || // Is there an exact pointer match?
                wordType == WORD_TYPE_VARIABLE) { // Is the current lookup word a variable?
                lookupImpl(interp, results, resultsidx, maxresults,
                           trie->branches[j], clause, clauseidx + 1);

            } else if (wordType == WORD_TYPE_REST_VARIABLE) {
                lookupAll(results, resultsidx, maxresults, trie->branches[j]);
                
            } else {
                char keyVarName[100];
                // Is the trie node (we're currently walking) a variable?
                if (scanVariable(trie->branches[j]->key, keyVarName, 100)) {
                    // Is the trie node a rest variable?
                    if (keyVarName[0] == '.' && keyVarName[1] == '.' && keyVarName[2] == '.') {
                        lookupAll(results, resultsidx, maxresults, trie->branches[j]);

                    } else { // Or is the trie node a normal variable?
                        lookupImpl(interp, results, resultsidx, maxresults,
                                   trie->branches[j], clause, clauseidx + 1);
                    }
                } else {
                    const char *keyString = Jim_String(trie->branches[j]->key);
                    const char *wordString = Jim_String(word);
                    if (strcmp(keyString, wordString) == 0) {
                        lookupImpl(interp, results, resultsidx, maxresults,
                                   trie->branches[j], clause, clauseidx + 1);
                    }
                }
            }
        }
    }
    $cc proc lookup {Jim_Interp* interp
                     uint64_t* results size_t maxresults
                     trie_t* trie Jim_Obj* pattern} int {
        int resultcount = 0;
        lookupImpl(interp, results, &resultcount, maxresults,
                   trie, pattern, 0);
        return resultcount;
    }
    $cc proc lookupJimObjs {Jim_Interp* interp trie_t* trie Jim_Obj* pattern} Jim_Obj* {
        uint64_t results[50];
        int resultcount = lookup(interp, results, 50, trie, pattern);
        if (resultcount >= 50) { exit(1); }

        Jim_Obj* resultsobj = Jim_NewListObj(interp, NULL, 0);
        for (int i = 0; i < resultcount; i++) {
            Jim_ListAppendElement(interp, resultsobj, Jim_ObjPrintf(interp, "%d", (int)results[i]));
        }
        return resultsobj;
    }

    # Only looks for literal matches of `literal` in the trie
    # (does not treat /variable/ as a variable). Used to check for an
    # already-existing statement whenever a statement is inserted.
    $cc proc lookupLiteralImpl {Jim_Interp* interp
                                uint64_t* results int* resultsidx size_t maxresults
                                trie_t* trie Jim_Obj* clause int clauseidx} void {
        int wordc = Jim_ListLength(interp, clause) - clauseidx;
        if (wordc == 0) {
            if (trie->hasValue) {
                if (*resultsidx < maxresults) {
                    results[(*resultsidx)++] = trie->value;
                }
            }
            return;
        }

        Jim_Obj* word = Jim_ListGetIndex(interp, clause, clauseidx);

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }

            if (trie->branches[j]->key == word) { // Is there an exact pointer match?
                lookupLiteralImpl(interp, results, resultsidx, maxresults,
                           trie->branches[j], clause, clauseidx + 1);
            } else {
                const char *keyString = Jim_String(trie->branches[j]->key);
                const char *wordString = Jim_String(word);
                if (strcmp(keyString, wordString) == 0) {
                    lookupLiteralImpl(interp, results, resultsidx, maxresults,
                                      trie->branches[j], clause, clauseidx + 1);
                }
            }
        }
    }
    $cc proc lookupLiteral {Jim_Interp* interp
                            uint64_t* results size_t maxresults
                            trie_t* trie Jim_Obj* literal} int {
        int resultcount = 0;
        lookupLiteralImpl(interp, results, &resultcount, maxresults,
                          trie, literal, 0);
        return resultcount;
    }

    $cc proc tclify {trie_t* trie} Jim_Obj* {
        int objc = 2 + trie->nbranches;
        Jim_Obj* objv[objc];
        objv[0] = trie->key ? trie->key : Jim_ObjPrintf(interp, "ROOT");
        objv[1] = trie->value ? Jim_ObjPrintf(interp, "%"PRIu64, trie->value) : Jim_ObjPrintf(interp, "NULL");
        for (int i = 0; i < trie->nbranches; i++) {
            objv[2+i] = trie->branches[i] ? tclify(trie->branches[i]) : Jim_NewStringObj(interp, "", 0);
        }
        return Jim_NewListObj(interp, objv, objc);
    }
    proc dot {trie} {
        proc idify {word} {
            # generate id-able word by eliminating all non-alphanumeric
            regsub -all {\W+} $word "_"
        }
        proc labelify {word} {
            # shorten the longest lines
            set word [join [lmap line [split $word "\n"] {
                expr { [string length $line] > 80 ? "[string range $line 0 80]..." : $line }
            }] "\n"]
            string map {"\"" "\\\""} $word
        }
        proc subdot {path subtrie} {
            set branches [lassign $subtrie key id]
            set pathkey [idify $key]
            set newpath [list {*}$path $pathkey]

            set dot [list]
            lappend dot "[join $newpath "_"] \[label=\"[labelify $key]\"\];"
            lappend dot "\"[join $path "_"]\" -> \"[join $newpath "_"]\";"
            foreach branch $branches {
                if {$branch == {}} continue
                lappend dot [subdot $newpath $branch]
            }
            return [join $dot "\n"]
        }
        return "digraph { rankdir=LR; [subdot {} [tclify $trie]] }"
    }

    $cc compile

    rename remove_ remove
    rename scanVariable scanVariableC
    rename scanVariable_ scanVariable
    namespace export *
    namespace ensemble create
}

# Compatibility with test/trie and old Jim impl of trie.
namespace eval trie {
    namespace import ::ctrie::*
    namespace export *
    rename add add_; rename addWithVar add
    rename remove remove_; rename removeWithVar remove
    rename lookup lookup_; rename lookupJimObjs lookup
    namespace ensemble create
}
