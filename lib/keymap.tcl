namespace eval keymap {
    try {
        # C implementation based on libkeymap
        # libkeymap is part of the kbd package, but most distros don't --enable-libkeymap
        c loadlibLd libkeymap.so
        c loadlibLd libkbdfile.so

        rename [c create] kc

        kc include <stdio.h>
        kc include <stdlib.h>
        kc include <string.h>
        kc include <keymap.h>
        kc include <kbdfile.h>
        kc include <linux/keyboard.h>

        kc code {
            static const char *const dirpath[] = {
              ".",
              "/usr/lib/kbd/keymaps/**",
              "/usr/share/kbd/keymaps/**",
              NULL
            };

            static const char *const suffixes[] = {
              "",
              ".kmap",
              ".map",
              NULL
            };

            typedef struct lk_ctx lkctx_t;
        }

        kc argtype lkctx_t* {
            lkctx_t* $argname; sscanf(Tcl_GetString($obj), "(lkctx_t*) 0x%p", &$argname);
        }

        kc rtype lkctx_t* {
            $robj = Tcl_ObjPrintf("(lkctx_t*) 0x%" PRIxPTR, (uintptr_t) $rvalue);
        }

        kc proc load {char* name} lkctx_t* {
            lkctx_t* ctx = lk_init();
            // @TODO assert failures
            struct kbdfile_ctx* fctx = kbdfile_context_new();
            struct kbdfile* file = kbdfile_new(fctx);
            kbdfile_find(name, dirpath, suffixes, file);
            lk_parse_keymap(ctx, file);
            lk_add_constants(ctx);
            kbdfile_close(file);
            kbdfile_context_free(fctx);
            return ctx;
        }

        kc proc resolve {lkctx_t* ctx
                         int key
                         int mods} Tcl_Obj* {
            if (!lk_map_exists(ctx, mods)) return Tcl_NewStringObj("", 0);

            char* ksym;
            char* unichar;
            Tcl_Obj* result[2];

            // see https://github.com/legionus/kbd/blob/master/src/libkeymap/dump.c#L361-L395
            int code = lk_get_key(ctx, mods, key);
            if (KTYP(code) == KT_LETTER) {
                // this key should be affected by capslock, but do we care?
                code = K(KT_LATIN, KVAL(code));
                ksym = lk_code_to_ksym(ctx, code);
            } else if (KTYP(code) == KT_META && KVAL(code) < 128) {
                code = K(KT_LATIN, KVAL(code));

                char* base = lk_code_to_ksym(ctx, code);
                asprintf(&ksym, "Meta_%s", base);
                free(base);
            } else {
                ksym = lk_code_to_ksym(ctx, code);
            }

            if (ksym == NULL) {
                free(ksym);
                return Tcl_NewStringObj("", 0);
            } else {
                result[0] = Tcl_NewStringObj(ksym, -1);
            }

            int codepoint = lk_ksym_to_unicode(ctx, ksym);
            if (codepoint < 0) {
                result[1] = Tcl_NewStringObj("", 0);
            } else {
                asprintf(&unichar, "%c", codepoint);
                result[1] = Tcl_NewStringObj(unichar, -1);
            }

            free(ksym);
            free(unichar);
            return Tcl_NewListObj(2, result);
        }

        kc proc dump {lkctx_t* ctx} void {
            lk_dump_keymaps(ctx, stdout);
            lk_dump_keys(ctx, stdout, LK_SHAPE_FULL_TABLE, 0);
        }

        kc proc destroy {lkctx_t* ctx} void {
            lk_free(ctx);
        }

        kc compile

        namespace export *
    } on error e {
        puts "Error $e"

        # Tcl implementation using loadkeys/dumpkeys
        # needs debian packages: console-data
        proc _fillRange {range} {
            lassign [split $range -] from to
            if {$to eq ""} {return $from}

            set out [list]
            for {set i $from} {$i <= $to} {incr i} {
                lappend out $i
            }
            return $out
        }

        proc _parseKey {key} {
            if {$key eq "VoidSymbol"} return

            if {[string index $key 0] eq "+"} {
                return [string range $key 1 end]
            }

            return $key
        }

        proc _parseUnicode {key} {
            switch [string index $key 0] {
                "U" {
                    set key 0x[string range $key 2 end]
                    if {!$key} return
                }

                "+" {
                    # map from KT_LETTER to KT_LATIN
                    set key [string range $key 1 end]
                    set key [expr $key & 0xff]
                }
            }

            if {$key & 0xff00} return ;# only support KT_LATIN
            if {$key < 32 || $key == 127} return ;# no control chars

            return [format %c $key]
        }

        proc load {name} {
            exec kbd_mode -u $name
            set keytable [exec dumpkeys -kf]
            set unitable [exec dumpkeys -kfn]

            set ksyms [dict create]
            set mods [_fillRange 0-15]
            foreach line [split $keytable "\n"] {
                switch [lindex $line 0] {
                    keymaps {
                        set map [split [lindex $line 1] ,]
                        set mods [concat {*}[lmap r $map {_fillRange $r}]]
                    }

                    keycode {
                        set code [lindex $line 1]
                        set modi 0
                        foreach key [lrange $line 3 end] {
                            set mod [lindex $mods $modi]
                            set str [_parseKey $key]
                            if {$str eq ""} continue

                            dict append ksyms "$code $mod" $str
                            incr modi
                        }
                    }
                }
            }

            set chars [dict create]
            set mods [_fillRange 0-15]
            foreach line [split $unitable "\n"] {
                switch [lindex $line 0] {
                    keymaps {
                        set map [split [lindex $line 1] ,]
                        set mods [concat {*}[lmap r $map {_fillRange $r}]]
                    }

                    keycode {
                        set code [lindex $line 1]
                        set modi 0
                        foreach key [lrange $line 3 end] {
                            set mod [lindex $mods $modi]
                            set str [_parseUnicode $key]
                            if {$str eq ""} continue

                            dict append chars "$code $mod" $str
                            incr modi
                        }
                    }
                }
            }

            return [list $ksyms $chars]
        }

        # takes km, keycode and mod-bitfield, returns [ksym char] tuple
        # char is printable representation of ksym, or "" if unprintable
        proc resolve {km code mod} {
            lassign $km ksyms chars
            set kk "$code $mod"

            if {![dict exists $ksyms $kk]} return
            return [list [dict get $ksyms $kk] [dict_getdef $chars $kk ""]]
        }

        proc dump {km} {
            lassign $km ksyms _
            set range 0-15
            puts "keymap $range"
            set mods [_fillRange $range]
            puts $ksyms
            for {set code 1} {$code < 256} {incr code} {
                set out [lmap mod $mods {dict_getdef $ksyms "$code $mod" VoidSymbol}]
                puts "keycode $code = [join $out \t]"
            }
        }

        proc destroy {km} {} ;# for compatibility with C impl
        namespace export load dump resolve destroy
    }

    set modWeights {
      Shift 1
      AltGr 2
      Control 4
      Alt 8
    }

    namespace export modWeights
    namespace ensemble create
}

if {$::argv0 eq [info script]} {
    set tkm [keymap load "us"]

    keymap dump $tkm

    for {set i 0} {$i < 15} {incr i} {
        puts "30/$i [keymap resolve $tkm 30 $i]"
    }
    puts "252/0 [keymap resolve $tkm 252 0]"
    foreach code {5 12 27} {
      puts "$code/0 [keymap resolve $tkm $code 0]"
    }
    keymap destroy $tkm
}
