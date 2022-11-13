namespace eval c {
    # critcl::ccode {
    #     #define _GNU_SOURCE
    #     #include <unistd.h>
    #     #include <inttypes.h>
    #     #include <stdlib.h>
    # }
    # ::proc struct {type fields} {
    #     critcl::ccode [subst {
    #         typedef struct $type {
    #             $fields
    #         } $type;
    #     }]

    #     critcl::argtype $type* [subst -nobackslashes {
    #         sscanf(Tcl_GetString(@@), "($type*) 0x%p", &@A);
    #     }]
    #     critcl::resulttype $type* [subst -nobackslashes {
    #         Tcl_SetObjResult(interp, Tcl_ObjPrintf("($type*) 0x%" PRIxPTR, (uintptr_t) rv));
    #         return TCL_OK;
    #     }]
    # }

    variable prelude {
        #include <tcl.h>
        #include <inttypes.h>
        #include <stdint.h>
    }
    variable code [list]
    variable procs [dict create]

    ::proc include {h} {
        variable code
        lappend code "#include $h"
    }
    ::proc struct {type fields} {
        variable code
        lappend code [subst {
            typedef struct $type $type;
            struct $type {
                $fields
            };
        }]
    }

    ::proc "proc" {name args rtype body} {
        # puts "$name $args $rtype $body"

        set arglist [list]
        set argnames [list]
        set loadargs [list]
        for {set i 0} {$i < [llength $args]} {incr i 2} {
            set argtype [lindex $args $i]
            set argname [lindex $args [expr {$i+1}]]
            lappend arglist "$argtype $argname"
            lappend argnames $argname

            if {$argtype == "Tcl_Interp*" && $argname == "interp"} { continue }

            set obj [subst {objv\[1 + [llength $loadargs]\]}]
            lappend loadargs [subst {
                $argtype $argname;
                [subst [switch $argtype {
                    int { expr {{ Tcl_GetIntFromObj(interp, $obj, &$argname); }}}
                    Tcl_Obj* { expr {{ $argname = $obj; }}}
                    trie_t* { expr {{ sscanf(Tcl_GetString($obj), "(trie_t*) 0x%p", &$argname); }}}
                    Tcl_Obj** { expr {{ sscanf(Tcl_GetString($obj), "(Tcl_Obj**) 0x%p", &$argname); }}}
                    default { error "Unrecognized argtype $argtype" }
                }]]
            }]
        }
        if {$rtype == "void"} {
            set saverv [subst {
                $name ([join $argnames ", "]);
                return TCL_OK;
            }]
        } else {
            set saverv [subst {
                $rtype rv = $name ([join $argnames ", "]);
                [switch $rtype {
                    int { expr {{
                        Tcl_SetObjResult(interp, Tcl_NewIntObj(rv));
                        return TCL_OK;
                    }}}
                    Tcl_Obj* { expr {{
                        Tcl_SetObjResult(interp, rv);
                        return TCL_OK;
                    }}}
                    trie_t* { expr {{
                        Tcl_SetObjResult(interp, Tcl_ObjPrintf("(trie_t*) 0x%" PRIxPTR, (uintptr_t) rv));
                        return TCL_OK;
                    }}}
                    default { error "Unrecognized rtype $rtype" }
                }]
            }]
        }
        
        set uniquename [string map {":" "_"} [uplevel [list namespace current]]]__$name
        variable procs
        dict set procs $name [subst {
            static $rtype $name ([join $arglist ", "]) {
                $body
            }

            static int [set name]_Cmd(ClientData cdata, Tcl_Interp* interp, int objc, Tcl_Obj* const objv\[]) {
                if (objc != 1 + [llength $loadargs]) {
                    Tcl_SetResult(interp, "Wrong number of arguments to $name", NULL);
                    return TCL_ERROR;
                }
                [join $loadargs "\n"]
                $saverv
            }
        }]
    }

    ::proc compile {} {
        variable prelude
        variable code
        variable procs

        set init [subst {
            int Cfile_Init(Tcl_Interp* interp) {
                [join [lmap name [dict keys $procs] { subst {
                    Tcl_CreateObjCommand(interp, "[uplevel [list namespace current]]::$name", [set name]_Cmd, NULL, NULL);
                }}] "\n"]
                return TCL_OK;
            }
        }]
        set sourcecode [join [list $prelude {*}$code {*}[dict values $procs] $init] "\n"]
        
        # puts "=====================\n$sourcecode\n====================="

        set cfd [file tempfile cfile cfile.c]; puts $cfd $sourcecode; close $cfd
        exec cc -Wall -g -shared -I$::tcl_library/../../Headers $::tcl_library/../../Tcl $cfile -o [file rootname $cfile].dylib
        load [file rootname $cfile].dylib cfile

        set code [list]
        set procs [dict create]
    }

    namespace export *
    namespace ensemble create
}

proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

c proc add {int a int b} int {
    return a + b;
}
c compile
assert {[add 2 3] == 5}

namespace eval ctrie {
    c include <stdlib.h>
    c include <string.h>
    c struct trie_t {
        Tcl_Obj* key;

        int id; // or -1

        size_t nbranches;
        trie_t* branches[];
    }

    c proc create {} trie_t* {
        trie_t* ret = calloc(sizeof(trie_t) + 10*sizeof(trie_t*), 1);
        *ret = (trie_t) {
            .key = NULL,
            .id = -1,
            .nbranches = 10
        };
        return ret;
    }

    c proc add {Tcl_Interp* interp trie_t* trie Tcl_Obj* clause int id} void {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, clause, &objc, &objv) != TCL_OK) {
            exit(1);
        }

        for (int i = 0; i < objc; i++) {
            trie_t* branch = NULL;
            int j;
            for (j = 0; j < trie->nbranches; j++) {
                if (trie->branches[j] == NULL) { break; }
                if (trie->branches[j]->key == objv[i] ||
                    strcmp(Tcl_GetString(trie->branches[j]->key), Tcl_GetString(objv[i])) == 0) {
                    branch = trie->branches[j];
                    break;
                }
            }
            // TODO: if j == trie->nbranches then realloc
            if (trie->branches[j] == NULL) {
                branch = calloc(sizeof(trie_t) + 10*sizeof(trie_t*), 1);
                branch->key = objv[i];
                Tcl_IncrRefCount(branch->key);
                branch->id = -1;
                branch->nbranches = 10;
                trie->branches[j] = branch;
            }
            trie = branch;
        }
        trie->id = id;
    }
    c proc removeImpl {trie_t* trie int wordc Tcl_Obj** wordv} int {
        if (wordc == 0) return 1;

        for (int j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }
            if (trie->branches[j]->key == wordv[0] ||
                strcmp(Tcl_GetString(trie->branches[j]->key), Tcl_GetString(wordv[0])) == 0) {
                /* printf("match %d %s %s\n", j, Tcl_GetString(trie->branches[j]->key), Tcl_GetString(wordv[0])); */
                if (removeImpl(trie->branches[j], wordc - 1, wordv + 1)) {
                    Tcl_DecrRefCount(trie->branches[j]->key);
                    free(trie->branches[j]);
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
    c proc remove_ {Tcl_Interp* interp trie_t* trie Tcl_Obj* clause} void {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, clause, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        removeImpl(trie, objc, objv);
    }

    c proc lookupImpl {trie_t* trie int wordc Tcl_Obj** wordv} Tcl_Obj* {
        if (wordc == 0) { return Tcl_ObjPrintf("%d", trie->id); }

        Tcl_Obj* results[trie->nbranches];
        int j;
        for (j = 0; j < trie->nbranches; j++) {
            if (trie->branches[j] == NULL) { break; }

            int potentialMatch = 0;
            potentialMatch = potentialMatch || (trie->branches[j]->key == wordv[0]);
            const char *keyString = Tcl_GetString(trie->branches[j]->key);
            const char *wordString = Tcl_GetString(wordv[0]);
            potentialMatch = potentialMatch ||
                (keyString[0] == '/') ||
                (wordString[0] == '/') ||
                (strcmp(keyString, wordString) == 0);
            if (potentialMatch) {
                results[j] = lookupImpl(trie->branches[j], wordc - 1, wordv + 1);
            } else {
                results[j] = Tcl_ObjPrintf("");
            }
        }
        return Tcl_NewListObj(j, results);
    }
    c proc lookup {Tcl_Interp* interp trie_t* trie Tcl_Obj* pattern} Tcl_Obj* {
        int objc; Tcl_Obj** objv;
        if (Tcl_ListObjGetElements(interp, pattern, &objc, &objv) != TCL_OK) {
            exit(1);
        }
        return lookupImpl(trie, objc, objv);
    }

    c proc tclify {trie_t* trie} Tcl_Obj* {
        int objc = 2 + trie->nbranches;
        Tcl_Obj* objv[objc];
        objv[0] = trie->key ? trie->key : Tcl_ObjPrintf("ROOT");
        objv[1] = Tcl_NewIntObj(trie->id);
        for (int i = 0; i < trie->nbranches; i++) {
            objv[2+i] = trie->branches[i] ? tclify(trie->branches[i]) : Tcl_ObjPrintf("");
        }
        return Tcl_NewListObj(objc, objv);
    }
    proc dot {trie} {
        proc idify {word} {
            # generate id-able word by eliminating all non-alphanumeric
            regsub -all {\W+} $word "_"
        }
        proc labelify {word} {
            string map {"\"" "\\\""} [string map {"\\" "\\\\"} $word]
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
        return "digraph { rankdir=LR; [subdot {} $trie] }"
    }

    c compile
    rename remove_ remove
    namespace export create add remove lookup tclify dot
    namespace ensemble create
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    set t [ctrie create]
    # puts "made trie: $t"
    # puts [ctrie dot [ctrie tclify $t]]
    ctrie add $t [list Omar is a person] 601
    ctrie add $t [list Omar is a name] 602
    puts [ctrie tclify $t]
    exec dot -Tpdf <<[ctrie dot [ctrie tclify $t]] >ctrie-add.pdf
    ctrie remove $t [list Omar is a name]
    puts [ctrie tclify $t]
    exec dot -Tpdf <<[ctrie dot [ctrie tclify $t]] >ctrie-add-remove.pdf

    ctrie add $t [list Omar is a human] 603
    puts [ctrie lookup $t [list Omar is a person]]
    puts [ctrie lookup $t [list Omar is a human]]
    puts [ctrie lookup $t [list Omar is a /x/]]

    ctrie add $t [list Foo is a person] 501
    puts [ctrie lookup $t [list /p/ is a person]]
    exec dot -Tpdf <<[ctrie dot [ctrie tclify $t]] >ctrie-x.pdf
}
