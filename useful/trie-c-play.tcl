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

    variable code [list]
    ::proc include {h} {
        lappend c::code "#include $h"
    }
    ::proc struct {type fields} {
        lappend c::code [subst {
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
        set code [subst {
            #include <tcl.h>
            #include <inttypes.h>
            #include <stdint.h>

            [join $c::code "\n"]

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

            int [string totitle $uniquename]_Init(Tcl_Interp* interp) {
                Tcl_CreateObjCommand(interp, "[uplevel [list namespace current]]::$name", [set name]_Cmd, NULL, NULL);
                return TCL_OK;
            }
        }]

        # puts "=====================\n$code\n====================="

        set cfd [file tempfile cfile $name.c]; puts $cfd $code; close $cfd
        exec cc -Wall -g -shared -I$::tcl_library/../../Headers $::tcl_library/../../Tcl $cfile -o [file rootname $cfile].dylib
        load [file rootname $cfile].dylib $uniquename
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

        /* trie_t* branch = NULL; */
        for (int i = 0; i < objc; i++) {
            trie_t* branch = NULL;
            int j;
            for (j = 0; j < trie->nbranches; j++) {
                // TODO: check if key exists already
                if (trie->branches[j] == NULL) { break; }
                // printf("%s (%p) vs %s (%p)\n", Tcl_GetString(trie->branches[j]->key), trie->branches[j]->key, Tcl_GetString(objv[i]), objv[i]);
                if (trie->branches[j]->key == objv[i] || strcmp(Tcl_GetString(trie->branches[j]->key), Tcl_GetString(objv[i])) == 0) {
                    // printf("MATCH\n");
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
    c proc lookup {trie_t* trie Tcl_Obj* pattern} int {
        // for (x in pattern) {
        
        // }
        return 0;
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

    namespace export create add lookup tclify dot
    namespace ensemble create
}

set t [ctrie create]
# puts "made trie: $t"
# puts [ctrie dot [ctrie tclify $t]]
ctrie add $t [list Omar is a person] 601
ctrie add $t [list Omar is a name] 602
puts [ctrie tclify $t]
exec dot -Tpdf <<[ctrie dot [ctrie tclify $t]] >ctrie.pdf
