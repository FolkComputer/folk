/*
 *  TclTCC - Tcl binding to Tiny C Compiler
 * 
 *  Copyright (c) 2007 Mark Janssen
 *  Copyright (c) 2014 Roy Keene
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include <tcl.h>
#include <stdlib.h>
#include "tcc.h"

struct TclTCCState {
	TCCState *s;
	int relocated;
};

static void Tcc4tclErrorFunc(Tcl_Interp * interp, char * msg) {
	Tcl_AppendResult(interp, msg, "\n", NULL);
}

static void Tcc4tclCCommandDeleteProc(ClientData cdata) {
	struct TclTCCState *ts;
	TCCState *s ;

	ts = (struct TclTCCState *) cdata;
	s = ts->s;

	ts->s = NULL;

	ckfree((void *) ts);
}

static void Tcc4tclDeleteClientData(ClientData cdata) {
	/*
	 * ClientData is a Tcl_Obj*, that was passed in 
	 * at command creation
	 */
	Tcl_Obj *cdata_o = (Tcl_Obj *)cdata;

	if (cdata_o != NULL) {
		Tcl_DecrRefCount(cdata_o);
	}
}

static int Tcc4tclHandleCmd ( ClientData cdata, Tcl_Interp *interp, int objc, Tcl_Obj * CONST objv[]){
	Tcl_WideInt val;
	Tcl_Obj *val_o;
	void *val_p;
	int index;
	int res;
	struct TclTCCState *ts;
	TCCState *s;
	Tcl_Obj *sym_addr;
	static CONST char *options[] = {
		"add_include_path", "add_file",  "add_library", 
		"add_library_path", "add_symbol", "command", "compile",
		"define", "get_symbol", "output_file", "undefine",
		(char *) NULL
	};
	enum options {
		TCC4TCL_ADD_INCLUDE, TCC4TCL_ADD_FILE, TCC4TCL_ADD_LIBRARY, 
		TCC4TCL_ADD_LIBRARY_PATH, TCC4TCL_ADD_SYMBOL, TCC4TCL_COMMAND, TCC4TCL_COMPILE,
		TCC4TCL_DEFINE, TCC4TCL_GET_SYMBOL, TCC4TCL_OUTPUT_FILE, TCC4TCL_UNDEFINE
	};
	char *str;
	int rv;

	ts = (struct TclTCCState *) cdata;
	s = ts->s;

    if (objc < 2) {
        Tcl_WrongNumArgs(interp, 1, objv, "subcommand arg ?arg ...?");
        return TCL_ERROR;
    }

    if (Tcl_GetIndexFromObj(interp, objv[1], options, "option", 0,
                &index) != TCL_OK) {
        return TCL_ERROR;
    }
    switch (index) {
        case TCC4TCL_ADD_INCLUDE:   
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "path");
                return TCL_ERROR;
            } else {
                tcc_add_include_path(s, Tcl_GetString(objv[2]));
                return TCL_OK;
            }
        case TCC4TCL_ADD_FILE:   
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "filename");
                return TCL_ERROR;
            } else {
                if(tcc_add_file(s, Tcl_GetString(objv[2]))!=0) {
                    return TCL_ERROR;
                } else {
                    return TCL_OK;
                }
            }
        case TCC4TCL_ADD_LIBRARY:
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "lib");
                return TCL_ERROR;
            } else {
                tcc_add_library(s, Tcl_GetString(objv[2]));
                return TCL_OK;
            }
        case TCC4TCL_ADD_LIBRARY_PATH:
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "path");
                return TCL_ERROR;
            } else {
                tcc_add_library_path(s, Tcl_GetString(objv[2]));
                return TCL_OK;
            }
        case TCC4TCL_ADD_SYMBOL:
            if (objc != 4) {
                Tcl_WrongNumArgs(interp, 2, objv, "symbol value");
                return TCL_ERROR;
            }

            rv = Tcl_ExprObj(interp, Tcl_ObjPrintf("wide(%s)", Tcl_GetString(objv[3])), &val_o);
            if (rv != TCL_OK) {
                return TCL_ERROR;
            }

            rv = Tcl_GetWideIntFromObj(interp, val_o, &val);
            if (rv != TCL_OK) {
                return TCL_ERROR;
            }

            val_p = (void *) val;

            tcc_add_symbol(s,Tcl_GetString(objv[2]), val_p); 
            return TCL_OK; 
        case TCC4TCL_COMMAND:
            if (objc != 4 && objc != 5) {
                Tcl_WrongNumArgs(interp, 2, objv, "tclname cname ?clientData?");
                return TCL_ERROR;
            }

            if (!ts->relocated) {     
                if(tcc_relocate(s, TCC_RELOCATE_AUTO)!=0) {
                    Tcl_AppendResult(interp, "relocating failed", NULL);
                    return TCL_ERROR;
                } else {
                    ts->relocated=1;
                }
            }

            val_p = tcc_get_symbol(s, Tcl_GetString(objv[3]));
            if (val_p == NULL) {
		    Tcl_AppendResult(interp, "symbol '", Tcl_GetString(objv[3]),"' not found", NULL);
		    return TCL_ERROR;
	    }

	    /* the ClientData */
	    if (objc == 5) {
		val_o = objv[4];
		Tcl_IncrRefCount(val_o);
	    } else {
		val_o = NULL;
	    }

            /*printf("symbol: %x\n",val); */
            Tcl_CreateObjCommand(interp, Tcl_GetString(objv[2]), val_p, val_o, Tcc4tclDeleteClientData);
            return TCL_OK;
        case TCC4TCL_COMPILE:
            if(ts->relocated == 1) {
                Tcl_AppendResult(interp, "code already relocated, cannot compile more",NULL);
                return TCL_ERROR;
            }
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "ccode");
                return TCL_ERROR;
            } else {

                int i;
                Tcl_GetString(objv[2]);
                i = tcc_compile_string(s,Tcl_GetString(objv[2]));
                if (i!=0) {
                    Tcl_AppendResult(interp,"compilation failed",NULL);
                    return TCL_ERROR;
                } else {
                    return TCL_OK;
                }
            }
        case TCC4TCL_DEFINE:
            if (objc != 4) {
                Tcl_WrongNumArgs(interp, 2, objv, "symbol value");
                return TCL_ERROR;
            }
            tcc_define_symbol(s,Tcl_GetString(objv[2]),Tcl_GetString(objv[3]));
            return TCL_OK;
        case TCC4TCL_GET_SYMBOL:
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "symbol");
                return TCL_ERROR;
            }
            if (!ts->relocated) {     
                if(tcc_relocate(s, TCC_RELOCATE_AUTO)!=0) {
                    Tcl_AppendResult(interp, "relocating failed", NULL);
                    return TCL_ERROR;
                } else {
                    ts->relocated=1;
                }
            }
            val_p = tcc_get_symbol(s,Tcl_GetString(objv[2]));
            if(val_p == NULL) {
                Tcl_AppendResult(interp, "symbol '", Tcl_GetString(objv[2]),"' not found", NULL);
                return TCL_ERROR;
            }
            sym_addr = Tcl_NewWideIntObj((Tcl_WideInt) val_p);
            Tcl_SetObjResult(interp, sym_addr);
            return TCL_OK; 
        case TCC4TCL_OUTPUT_FILE:
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "filename");
                return TCL_ERROR;
            }
            if (ts->relocated) {     
                Tcl_AppendResult(interp, "code already relocated, cannot output to file", NULL);
                return TCL_ERROR;
            }
            if (s->output_type == TCC_OUTPUT_MEMORY) {     
                Tcl_AppendResult(interp, "output_type memory not valid for output to file", NULL);
                return TCL_ERROR;
            }
            res = tcc_output_file(s,Tcl_GetString(objv[2]));

            if (res!=0) {
                Tcl_AppendResult(interp, "output to file failed", NULL);
                return TCL_ERROR;
            } else {
                return TCL_OK;
            }
        case TCC4TCL_UNDEFINE:
            if (objc != 3) {
                Tcl_WrongNumArgs(interp, 2, objv, "symbol");
                return TCL_ERROR;
            }
            tcc_undefine_symbol(s,Tcl_GetString(objv[2]));
            return TCL_OK;
        default:
            Tcl_Panic("internal error during option lookup");
    }
    return TCL_OK;
} 

static int Tcc4tclCreateCmd( ClientData cdata, Tcl_Interp *interp, int objc, Tcl_Obj * CONST objv[]){
	struct TclTCCState *ts;
	TCCState *s;
    	int index;
	static CONST char *types[] = {
		"memory", "exe", "dll", "obj", "preprocess",    (char *) NULL
	};

	if (objc < 3 || objc > 4) {
		Tcl_WrongNumArgs(interp, 1, objv, "tcc_libary_path ?output_type? handle");
		return TCL_ERROR;
	}

	if (objc == 3) {
		index = TCC_OUTPUT_MEMORY;
	} else {
		if (Tcl_GetIndexFromObj(interp, objv[2], types, "type", 0, &index) != TCL_OK) {
			return TCL_ERROR;
		}
	}

	s = tcc_new(Tcl_GetString(objv[1]));
	if (s == NULL) {
		return(TCL_ERROR);
	}

#ifdef USE_TCL_STUBS
	if (index == TCC_OUTPUT_MEMORY) {
		/* Only add this symbol if we are compiling to memory */
		tcc_add_symbol(s, "tclStubsPtr", &tclStubsPtr);
	}

	tcc_define_symbol(s, "USE_TCL_STUBS", "1");
#endif

	tcc_set_error_func(s, interp, (void *)&Tcc4tclErrorFunc);

	ts = (void *) ckalloc(sizeof(*ts));
	ts->s = s;
    	ts->relocated = 0;

	/*printf("type: %d\n", index); */
	tcc_set_output_type(s,index);
	Tcl_CreateObjCommand(interp,Tcl_GetString(objv[objc-1]),Tcc4tclHandleCmd,ts,Tcc4tclCCommandDeleteProc);

	Tcl_SetObjResult(interp, objv[objc-1]);

	return TCL_OK;
}

int Tcc4tcl_Init(Tcl_Interp *interp) {
#ifdef USE_TCL_STUBS
	if (Tcl_InitStubs(interp, TCL_VERSION , 0) == 0L) {
		return TCL_ERROR;
	}
#endif

	Tcl_CreateObjCommand(interp, "tcc4tcl", Tcc4tclCreateCmd, NULL, NULL);

	return TCL_OK;
}
