namespace eval keymap {
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
                set key [expr {$key & 0xff}]
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

    variable modWeights {
      Shift 1
      AltGr 2
      Control 4
      Alt 8
    }
    namespace ensemble create
}

if {[info exists ::argv0] && $::argv0 eq [info script]} {
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
