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
    set cc [c create]
    $cc include <stdlib.h>
    $cc include <string.h>
    $cc include <stdbool.h>
    $cc code {
        typedef struct trie_t trie_t;
        struct trie_t {
            Tcl_Obj* key;

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
        trie_t* ret = (trie_t *) ckalloc(size); memset(ret, 0, size);
        *ret = (trie_t) {
            .key = NULL,
            .hasValue = false,
            .value = 0,
            .nbranches = 10
        };
        return ret;
    }

    $cc proc scanVariable {Tcl_Obj* wordobj char* outVarName size_t sizeOutVarName} int {
        const char* word; int wordlen; word = Tcl_GetStringFromObj(wordobj, &wordlen);
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
    # These functions operate on the Tcl string representation of a
    # value _without_ coercing the value into a pure string first, so
    # they avoid shimmering / are more efficient than using Tcl
    # builtin functions like `regexp` and `string index`.
    $cc proc scanVariable_ {Tcl_Obj* wordobj} Tcl_Obj* {
        char varName[100];
        if (scanVariable(wordobj, varName, 100) == false) {
            return Tcl_NewStringObj("false", -1);            
        }
        return Tcl_NewStringObj(varName, -1);
    }
    $cc proc startsWithDollarSign {Tcl_Obj* wordobj} bool {
        return Tcl_GetString(wordobj)[0] == '\$';
    }

    $cc proc addImpl {trie_t** trie int wordc Tcl_Obj** wordv uint64_t value} void {
        if (wordc == 0) {
            (*trie)->value = value;
            (*trie)->hasValue = true;
            return;
        }

        Tcl_Obj* word = wordv[0];

        trie_t** match = NULL;

        int j;
        for (j = 0; j < (*trie)->nbranches; j++) {
            trie_t** branch = &(*trie)->branches[j];
            if (*branch == NULL) { break; }

            if ((*branch)->key == word ||
                strcmp(Tcl_GetString((*branch)->key), Tcl_GetString(word)) == 0) {

                match = branch;
                break;
            }
        }

        if (match == NULL) { // add new branch
            if (j == (*trie)->nbranches) {
                // we're out of room, need to grow trie
                (*trie)->nbranches *= 2;
                *trie = (trie_t *) ckrealloc((char *) *trie, sizeof(trie_t) + (*trie)->nbranches*sizeof(trie_t*));
                memset(&(*trie)->branches[j], 0, ((*trie)->nbranches/2)*sizeof(trie_t*));
            }

            size_t size = sizeof(trie_t) + 10*sizeof(trie_t*);
            trie_t* branch = (trie_t *) ckalloc(size); memset(branch, 0, size);
            branch->key = word;
            Tcl_IncrRefCount(branch->key);
            branch->value = 0;
            branch->hasValue = false;
            branch->nbranches = 10;

            (*trie)->branches[j] = branch;
            match = &(*trie)->branches[j];
        }

        addImpl(match, wordc - 1, wordv + 1, value);
    }
    $cc proc add {Tcl_Interp* interp trie_t** trie Tcl_Obj* clause uint64_t value} void {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, clause, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        addImpl(trie, objc, objv, value);
    }
    $cc proc addWithVar {Tcl_Interp* interp Tcl_Obj* trieVar Tcl_Obj* clause uint64_t value} void {
        trie_t* trie; sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, trieVar, NULL, 0)), "(trie_t*) 0x%p", &trie);
        add(interp, &trie, clause, value);
        Tcl_ObjSetVar2(interp, trieVar, NULL, Tcl_ObjPrintf("(trie_t*) 0x%" PRIxPTR, (uintptr_t) trie), 0);
    }

    $cc proc removeImpl {trie_t* trie int wordc Tcl_Obj** wordv} int {
        if (wordc == 0) return 1;
        Tcl_Obj* word = wordv[0];

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }
            if (trie->branches[j]->key == word ||
                strcmp(Tcl_GetString(trie->branches[j]->key), Tcl_GetString(word)) == 0) {
                if (removeImpl(trie->branches[j], wordc - 1, wordv + 1)) {
                    Tcl_DecrRefCount(trie->branches[j]->key);
                    ckfree((char *) trie->branches[j]);
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
    $cc proc remove_ {Tcl_Interp* interp trie_t* trie Tcl_Obj* clause} void {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, clause, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        removeImpl(trie, objc, objv);
    }
    $cc proc removeWithVar {Tcl_Interp* interp Tcl_Obj* trieVar Tcl_Obj* clause} void {
        trie_t* trie; sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, trieVar, NULL, 0)), "(trie_t*) 0x%p", &trie);
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

    # Given a word sequence `wordc` & `wordv`, looks for all matches
    # in the trie `trie`.
    $cc proc lookupImpl {Tcl_Interp* interp
                         uint64_t* results int* resultsidx size_t maxresults
                         trie_t* trie int wordc Tcl_Obj** wordv} void {
        if (wordc == 0) {
            if (trie->hasValue) {
                if (*resultsidx < maxresults) {
                    results[(*resultsidx)++] = trie->value;
                }
            }
            return;
        }

        Tcl_Obj* word = wordv[0];
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
                           trie->branches[j], wordc - 1, wordv + 1);

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
                                   trie->branches[j], wordc - 1, wordv + 1);
                    }
                } else {
                    const char *keyString = Tcl_GetString(trie->branches[j]->key);
                    const char *wordString = Tcl_GetString(word);
                    if (strcmp(keyString, wordString) == 0) {
                        lookupImpl(interp, results, resultsidx, maxresults,
                                   trie->branches[j], wordc - 1, wordv + 1);
                    }
                }
            }
        }
    }
    $cc proc lookup {Tcl_Interp* interp
                     uint64_t* results size_t maxresults
                     trie_t* trie Tcl_Obj* pattern} int {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, pattern, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        int resultcount = 0;
        lookupImpl(interp, results, &resultcount, maxresults,
                   trie, objc, objv);
        return resultcount;
    }
    $cc proc lookupTclObjs {Tcl_Interp* interp trie_t* trie Tcl_Obj* pattern} Tcl_Obj* {
        uint64_t results[50];
        int resultcount = lookup(interp, results, 50, trie, pattern);
        if (resultcount >= 50) { exit(1); }

        Tcl_Obj* resultsobj = Tcl_NewListObj(resultcount, NULL);
        for (int i = 0; i < resultcount; i++) {
            Tcl_ListObjAppendElement(interp, resultsobj, Tcl_ObjPrintf("%d", (int)results[i]));
        }
        return resultsobj;
    }

    # Only looks for literal matches of `literal` in the trie
    # (does not treat /variable/ as a variable). Used to check for an
    # already-existing statement whenever a statement is inserted.
    $cc proc lookupLiteralImpl {Tcl_Interp* interp
                                uint64_t* results int* resultsidx size_t maxresults
                                trie_t* trie int wordc Tcl_Obj** wordv} void {
        if (wordc == 0) {
            if (trie->hasValue) {
                if (*resultsidx < maxresults) {
                    results[(*resultsidx)++] = trie->value;
                }
            }
            return;
        }

        Tcl_Obj* word = wordv[0];

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }

            if (trie->branches[j]->key == word) { // Is there an exact pointer match?
                lookupLiteralImpl(interp, results, resultsidx, maxresults,
                           trie->branches[j], wordc - 1, wordv + 1);
            } else {
                const char *keyString = Tcl_GetString(trie->branches[j]->key);
                const char *wordString = Tcl_GetString(word);
                if (strcmp(keyString, wordString) == 0) {
                    lookupLiteralImpl(interp, results, resultsidx, maxresults,
                                      trie->branches[j], wordc - 1, wordv + 1);
                }
            }
        }
    }
    $cc proc lookupLiteral {Tcl_Interp* interp
                            uint64_t* results size_t maxresults
                            trie_t* trie Tcl_Obj* literal} int {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, literal, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        int resultcount = 0;
        lookupLiteralImpl(interp, results, &resultcount, maxresults,
                          trie, objc, objv);
        return resultcount;
    }

    $cc proc tclify {trie_t* trie} Tcl_Obj* {
        int objc = 3 + trie->nbranches;
        Tcl_Obj* objv[objc];
        objv[0] = Tcl_ObjPrintf("x%" PRIxPTR, (uintptr_t) trie);
        objv[1] = trie->key ? trie->key : Tcl_ObjPrintf("ROOT");
        objv[2] = trie->value ? Tcl_ObjPrintf("%"PRIu64, trie->value) : Tcl_ObjPrintf("NULL");
        for (int i = 0; i < trie->nbranches; i++) {
            objv[3+i] = trie->branches[i] ? tclify(trie->branches[i]) : Tcl_NewStringObj("", 0);
        }
        return Tcl_NewListObj(objc, objv);
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
            string map {"\"" "\\\""} [string map {"\\" "\\\\"} $word]
        }
        proc subdot {subtrie} {
            set branches [lassign $subtrie ptr key id]

            set dot [list]
            lappend dot "$ptr \[label=\"[labelify $key]\"\];"
            foreach branch $branches {
                if {$branch eq {}} continue
                set branchptr [lindex $branch 0]
                lappend dot "$ptr -> $branchptr;"
                lappend dot [subdot $branch]
            }
            return [join $dot "\n"]
        }
        return "digraph { rankdir=LR; [subdot [tclify $trie]] }"
    }

    $cc compile

    rename remove_ remove
    rename scanVariable scanVariableC
    rename scanVariable_ scanVariable
    namespace export *
    namespace ensemble create
}

# Compatibility with test/trie and old Tcl impl of trie.
namespace eval trie {
    namespace import ::ctrie::*
    namespace export *
    rename add add_; rename addWithVar add
    rename remove remove_; rename removeWithVar remove
    rename lookup lookup_; rename lookupTclObjs lookup
    namespace ensemble create
}
