# This data structure has 2 differences from the average trie you
# might have seen before.
#
# 1. Its nodes are _entire tokens_, not characters.
#
#    someone -> wishes -> 30 -> is -> labelled -> Hello World
#
#    not
#
#    s -> o -> m -> e -> o -> n -> e -> SPACE -> w -> i -> ...
#
#    In other words, its alphabet is dynamic -- the set of all tokens
#    that programs are using in statements -- not 26 characters or
#    whatever.
#
# 2. Both search patterns and nodes can contain 'wildcards'.
#
#    This bidirectional matching is useful for incremental update.
#

namespace eval ctrie {
    set cc [c create]
    $cc include <stdlib.h>
    $cc include <string.h>
    $cc code {
        typedef struct trie_t trie_t;
        struct trie_t {
            Tcl_Obj* key;

            int id; // or -1

            size_t nbranches;
            trie_t* branches[];
        };
    }

    $cc proc create {} trie_t* {
        size_t size = sizeof(trie_t) + 10*sizeof(trie_t*);
        trie_t* ret = ckalloc(size); memset(ret, 0, size);
        *ret = (trie_t) {
            .key = NULL,
            .id = -1,
            .nbranches = 10
        };
        return ret;
    }

    $cc proc addImpl {trie_t** trie int wordc Tcl_Obj** wordv int id} void {
        if (wordc == 0) {
            (*trie)->id = id;
            return;
        }

        trie_t** match = NULL;

        int j;
        for (j = 0; j < (*trie)->nbranches; j++) {
            trie_t** branch = &(*trie)->branches[j];
            if (*branch == NULL) { break; }

            if ((*branch)->key == wordv[0] ||
                strcmp(Tcl_GetString((*branch)->key), Tcl_GetString(wordv[0])) == 0) {

                match = branch;
                break;
            }
        }

        if (match == NULL) { // add new branch
            if (j == (*trie)->nbranches) {
                // we're out of room, need to grow trie
                (*trie)->nbranches *= 2;
                *trie = ckrealloc(*trie, sizeof(trie_t) + (*trie)->nbranches*sizeof(trie_t*));
                memset(&(*trie)->branches[j], 0, ((*trie)->nbranches/2)*sizeof(trie_t*));
            }

            size_t size = sizeof(trie_t) + 10*sizeof(trie_t*);
            trie_t* branch = ckalloc(size); memset(branch, 0, size);
            branch->key = wordv[0];
            Tcl_IncrRefCount(branch->key);
            branch->id = -1;
            branch->nbranches = 10;

            (*trie)->branches[j] = branch;
            match = &(*trie)->branches[j];
        }

        addImpl(match, wordc - 1, wordv + 1, id);
    }
    $cc proc add {Tcl_Interp* interp trie_t** trie Tcl_Obj* clause int id} void {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, clause, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        addImpl(trie, objc, objv, id);
    }
    $cc proc addWithVar {Tcl_Interp* interp Tcl_Obj* trieVar Tcl_Obj* clause int id} void {
        trie_t* trie; sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, trieVar, NULL, 0)), "(trie_t*) 0x%p", &trie);
        add(interp, &trie, clause, id);
        Tcl_ObjSetVar2(interp, trieVar, NULL, Tcl_ObjPrintf("(trie_t*) 0x%" PRIxPTR, (uintptr_t) trie), 0);
    }

    $cc proc removeImpl {trie_t* trie int wordc Tcl_Obj** wordv} int {
        if (wordc == 0) return 1;

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }
            if (trie->branches[j]->key == wordv[0] ||
                strcmp(Tcl_GetString(trie->branches[j]->key), Tcl_GetString(wordv[0])) == 0) {
                /* printf("match %d %s %s\n", j, Tcl_GetString(trie->branches[j]->key), Tcl_GetString(wordv[0])); */
                if (removeImpl(trie->branches[j], wordc - 1, wordv + 1)) {
                    Tcl_DecrRefCount(trie->branches[j]->key);
                    ckfree(trie->branches[j]);
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
    $cc proc remove_ {Tcl_Interp* interp Tcl_Obj* trieVar Tcl_Obj* clause} void {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, clause, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        trie_t* trie; sscanf(Tcl_GetString(Tcl_ObjGetVar2(interp, trieVar, NULL, 0)), "(trie_t*) 0x%p", &trie);
        removeImpl(trie, objc, objv);
    }

    $cc proc lookupImpl {Tcl_Interp* interp Tcl_Obj* results
                        trie_t* trie int wordc Tcl_Obj** wordv} void {
        if (wordc == 0) {
            if (trie->id != -1) {
                Tcl_ListObjAppendElement(interp, results, Tcl_ObjPrintf("%d", trie->id));
            }
            return;
        }

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }

            if (trie->branches[j]->key == wordv[0]) {
                lookupImpl(interp, results, trie->branches[j], wordc - 1, wordv + 1);
            } else {
                const char *keyString = Tcl_GetString(trie->branches[j]->key);
                const char *wordString = Tcl_GetString(wordv[0]);
                if ((keyString[0] == '?' && keyString[1] == '\0') ||
                    (wordString[0] == '?' && wordString[1] == '\0') ||
                    (strcmp(keyString, wordString) == 0)) {
                    lookupImpl(interp, results, trie->branches[j], wordc - 1, wordv + 1);
                }
            }
        }
    }
    $cc proc lookup {Tcl_Interp* interp trie_t* trie Tcl_Obj* pattern} Tcl_Obj* {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, pattern, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        Tcl_Obj* results = Tcl_NewListObj(50, NULL);
        lookupImpl(interp, results, trie, objc, objv);
        return results;
    }

    $cc proc tclify {trie_t* trie} Tcl_Obj* {
        int objc = 2 + trie->nbranches;
        Tcl_Obj* objv[objc];
        objv[0] = trie->key ? trie->key : Tcl_ObjPrintf("ROOT");
        objv[1] = Tcl_NewIntObj(trie->id);
        for (int i = 0; i < trie->nbranches; i++) {
            objv[2+i] = trie->branches[i] ? tclify(trie->branches[i]) : Tcl_NewStringObj("", 0);
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
    namespace export create add addWithVar remove lookup tclify dot
    namespace ensemble create
}
