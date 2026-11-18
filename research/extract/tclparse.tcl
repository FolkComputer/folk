# tclparse.tcl -- a word-level parser for Jim Tcl scripts, written in Tcl.
#
# This is the host-layer grammar of docs/pl-research.md section 2.1 made
# executable. It does not evaluate anything: it splits a script into
# commands, commands into words, and words into parts, the way Jim's own
# tokenizer (JimParseScript in vendor/jimtcl/jim.c) does. difftest.tcl
# checks it against that tokenizer on the whole program corpus.
#
#   script   ::= { eol | comment | command }
#   command  ::= word { sep word }
#   word     ::= [ "{*}" ] part { part }
#   part     ::= braced | quoted-text | bare-text | var | cmd
#
# Result of [tp::parse $text]: a list of commands. Each command is a dict
#   line   line number of its first word
#   words  list of words
# Each word is a dict
#   line    line number where the word starts
#   expand  1 if the word is prefixed with {*}
#   form    braced | quoted | bare (how the word begins)
#   parts   list of {type text}; type is one of
#             str        text taken literally (inside braces)
#             esc        text needing only backslash substitution
#             var        $name or ${name}; text is the name
#             dictsugar  $name(index); text is "name(index)"
#             exprsugar  $(expr); text is "(expr)"
#             cmd        [script]; text is the script. A cmd part has a
#                        third element, the line the script starts on.
#
# All offsets are byte offsets, so that multi-byte characters cost nothing;
# every character that matters to the grammar is ASCII.

namespace eval tp {
    variable s ""        ;# script text
    variable n 0         ;# length of s in bytes
    variable i 0         ;# current byte offset
    variable ln 1        ;# current line number
    variable missing {}  ;# {char line} if a construct was left open
}

proc tp::parse {text {firstLine 1}} {
    variable s $text
    variable n [string bytelength $text]
    variable i 0
    variable ln $firstLine
    variable missing {}

    set commands {}
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\n" || $ch eq ";"} {
            tp::SkipEol
        } elseif {[tp::AtSep $ch]} {
            tp::SkipSep
        } elseif {$ch eq "#"} {
            tp::Comment
        } else {
            lappend commands [tp::Command]
        }
    }
    return $commands
}

# Did the last [tp::parse] end inside an open brace, quote or bracket?
# Returns {} or {char line}.
proc tp::missing {} {
    variable missing
    return $missing
}

# sep ::= ( space | tab | CR | FF | "\" newline ) { any-space-but-newline | "\" newline }
proc tp::AtSep {ch} {
    variable s; variable i
    expr {$ch eq " " || $ch eq "\t" || $ch eq "\r" || $ch eq "\f" ||
          ($ch eq "\\" && [string byterange $s $i+1 $i+1] eq "\n")}
}
proc tp::SkipSep {} {
    variable s; variable n; variable i; variable ln
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq " " || $ch eq "\t" || $ch eq "\r" || $ch eq "\f" ||
            $ch eq "\v"} {
            incr i
        } elseif {$ch eq "\\" && [string byterange $s $i+1 $i+1] eq "\n"} {
            incr ln; incr i 2
        } else {
            return
        }
    }
}

# eol ::= ( newline | ";" ) { any-space | ";" }
proc tp::SkipEol {} {
    variable s; variable n; variable i; variable ln
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\n"} {
            incr ln; incr i
        } elseif {$ch eq ";" || $ch eq " " || $ch eq "\t" || $ch eq "\r" ||
                  $ch eq "\f" || $ch eq "\v"} {
            incr i
        } else {
            return
        }
    }
}

# comment ::= "#" { any-char-but-newline | "\" any-char } newline
proc tp::Comment {} {
    variable s; variable n; variable i; variable ln
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\\"} {
            incr i
            if {[string byterange $s $i $i] eq "\n"} { incr ln }
        } elseif {$ch eq "\n"} {
            incr ln; incr i
            return
        }
        incr i
    }
}

# command ::= word { sep word }, ended by newline or ";"
proc tp::Command {} {
    variable s; variable n; variable i; variable ln
    set words {}
    set line $ln
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\n" || $ch eq ";"} {
            break
        } elseif {[tp::AtSep $ch]} {
            tp::SkipSep
        } else {
            if {[llength $words] == 0} { set line $ln }
            lappend words [tp::Word]
        }
    }
    return [dict create line $line words $words]
}

# word ::= [ "{*}" ] part { part }
proc tp::Word {} {
    variable s; variable n; variable i; variable ln; variable missing
    set line $ln
    set parts {}
    set form bare
    set inquote 0
    # Type of the previous token in this word: sep (none yet), str (a braced
    # part) or other. An open brace or a quote only opens a braced or quoted
    # part at the start of a word or straight after a braced part.
    set prev sep

    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {!$inquote} {
            if {$ch eq "\n" || $ch eq ";" || [tp::AtSep $ch]} { break }
        }

        if {$ch eq "\["} {
            set cmdLine $ln
            lappend parts [list cmd [tp::SubCmd] $cmdLine]
            set prev other
            continue
        }
        if {$ch eq "\$"} {
            set var [tp::Var]
            if {$var eq ""} {
                # A lone "$" is just text.
                lappend parts [list esc "\$"]
                incr i
            } else {
                lappend parts $var
            }
            set prev other
            continue
        }

        if {$prev eq "sep" || $prev eq "str"} {
            if {$ch eq "\{"} {
                if {$prev eq "sep"} { set form braced }
                lappend parts [list str [tp::SubBrace]]
                set prev str
                continue
            }
            if {$ch eq "\""} {
                if {$prev eq "sep"} { set form quoted }
                set inquote 1
                set quoteLine $ln
                incr i
            }
        }

        # Plain text up to the next substitution, separator or closing quote.
        set start $i
        set closed 0
        while {$i < $n} {
            set ch [string byterange $s $i $i]
            if {$ch eq "\\"} {
                set next [string byterange $s $i+1 $i+1]
                if {!$inquote && $next eq "\n"} { break }
                if {$i + 1 < $n} {
                    if {$next eq "\n"} { incr ln }
                    incr i
                } else {
                    set missing [list "\\" $ln]
                }
            } elseif {$ch eq "\$" || $ch eq "\["} {
                break
            } elseif {$inquote} {
                if {$ch eq "\""} { set closed 1; break }
                if {$ch eq "\n"} { incr ln }
            } elseif {$ch eq " " || $ch eq "\t" || $ch eq "\n" ||
                      $ch eq "\r" || $ch eq "\f" || $ch eq ";"} {
                break
            }
            incr i
        }
        lappend parts [list esc [string byterange $s $start $i-1]]
        if {$closed} { incr i; set inquote 0 }
        if {$inquote && $i >= $n} { set missing [list "\"" $quoteLine] }
        set prev other
    }

    # {*}word and {expand}word
    set expand 0
    if {[llength $parts] > 1} {
        lassign [lindex $parts 0] type text
        if {$type eq "str" && ($text eq "*" || $text eq "expand")} {
            set expand 1
            set parts [lrange $parts 1 end]
            lassign [lindex $parts 0] type text
            if {$type eq "str"} { set form braced }
        }
    }
    return [dict create line $line expand $expand form $form parts $parts]
}

# braced ::= "{" { any-char | "\" any-char | braced } "}"
# Returns the text between the braces. Leaves i after the closing brace.
proc tp::SubBrace {} {
    variable s; variable n; variable i; variable ln; variable missing
    set openLine $ln
    incr i
    set start $i
    set level 1
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\\"} {
            if {$i + 1 < $n} {
                incr i
                if {[string byterange $s $i $i] eq "\n"} { incr ln }
            }
        } elseif {$ch eq "\{"} {
            incr level
        } elseif {$ch eq "\}"} {
            if {[incr level -1] == 0} {
                set text [string byterange $s $start $i-1]
                incr i
                return $text
            }
        } elseif {$ch eq "\n"} {
            incr ln
        }
        incr i
    }
    set missing [list "\{" $openLine]
    return [string byterange $s $start $i-1]
}

# quoted text nested inside a [cmd]. Leaves i after the closing quote.
proc tp::SubQuote {} {
    variable s; variable n; variable i; variable ln; variable missing
    set openLine $ln
    incr i
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\\"} {
            if {$i + 1 < $n} {
                incr i
                if {[string byterange $s $i $i] eq "\n"} { incr ln }
            }
        } elseif {$ch eq "\""} {
            incr i
            return 1
        } elseif {$ch eq "\["} {
            tp::SubCmd
            continue
        } elseif {$ch eq "\n"} {
            incr ln
        }
        incr i
    }
    set missing [list "\"" $openLine]
    return 0
}

# cmd ::= "[" script "]"
# Returns the text between the brackets. Leaves i after the closing bracket.
proc tp::SubCmd {} {
    variable s; variable n; variable i; variable ln; variable missing
    set openLine $ln
    incr i
    set start $i
    set level 1
    set startofword 1
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\\"} {
            if {$i + 1 < $n} {
                incr i
                set ch [string byterange $s $i $i]
                if {$ch eq "\n"} { incr ln }
            }
        } elseif {$ch eq "\["} {
            incr level
        } elseif {$ch eq "\]"} {
            if {[incr level -1] == 0} {
                set text [string byterange $s $start $i-1]
                incr i
                return $text
            }
        } elseif {$ch eq "\""} {
            if {$startofword} {
                if {![tp::SubQuote]} {
                    return [string byterange $s $start $i-1]
                }
                continue
            }
        } elseif {$ch eq "\{"} {
            tp::SubBrace
            set startofword 0
            continue
        } elseif {$ch eq "\n"} {
            incr ln
        }
        set startofword [expr {$ch eq " " || $ch eq "\t" || $ch eq "\n" ||
                               $ch eq "\r" || $ch eq "\f" || $ch eq "\v"}]
        incr i
    }
    set missing [list "\[" $openLine]
    return [string byterange $s $start $i-1]
}

# var ::= "$" name | "${" chars "}" | "$" name "(" index ")" | "$(" expr ")"
# Returns {type text}, or "" if the "$" is not followed by a name (in which
# case i is left on the "$").
proc tp::Var {} {
    variable s; variable n; variable i; variable ln
    set dollar $i
    incr i
    if {[string byterange $s $i $i] eq "\{"} {
        incr i
        set start $i
        while {$i < $n && [string byterange $s $i $i] ne "\}"} {
            if {[string byterange $s $i $i] eq "\n"} { incr ln }
            incr i
        }
        set text [string byterange $s $start $i-1]
        if {$i < $n} { incr i }
        return [list var $text]
    }

    set start $i
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq ":" && [string byterange $s $i+1 $i+1] eq ":"} {
            while {[string byterange $s $i $i] eq ":"} { incr i }
        } elseif {[string match {[a-zA-Z0-9_]} $ch] || ![string is ascii -strict $ch]} {
            incr i
        } else {
            break
        }
    }
    set type var
    if {[string byterange $s $i $i] eq "("} {
        # $name(index) is sugar for [dict get $name index]; $(expr) is
        # sugar for [expr {expr}]. Jim scans for the matching paren without
        # regard to quotes, brackets or newlines.
        set type [expr {$i == $start ? "exprsugar" : "dictsugar"}]
        set count 1
        set paren -1
        while {$count && $i < $n} {
            incr i
            set ch [string byterange $s $i $i]
            if {$ch eq "\\" && $i < $n} {
                incr i
            } elseif {$ch eq "("} {
                incr count
            } elseif {$ch eq ")"} {
                set paren $i
                incr count -1
            }
        }
        if {$count == 0} {
            incr i
        } elseif {$paren >= 0} {
            set i [expr {$paren + 1}]
        }
    }
    if {$i == $start} {
        set i $dollar
        return ""
    }
    return [list $type [string byterange $s $start $i-1]]
}

# Tokenizes $text the way [subst] and [expr] see it: substitutions are
# recognised everywhere and nothing ends a word. Returns a list of parts.
proc tp::parseSubst {text {firstLine 1}} {
    variable s $text
    variable n [string bytelength $text]
    variable i 0
    variable ln $firstLine
    variable missing {}

    set parts {}
    set start 0
    while {$i < $n} {
        set ch [string byterange $s $i $i]
        if {$ch eq "\\"} {
            if {[string byterange $s $i+1 $i+1] eq "\n"} { incr ln }
            incr i 2
        } elseif {$ch eq "\[" || $ch eq "\$"} {
            if {$i > $start} {
                lappend parts [list esc [string byterange $s $start $i-1]]
            }
            if {$ch eq "\["} {
                set cmdLine $ln
                lappend parts [list cmd [tp::SubCmd] $cmdLine]
            } else {
                set var [tp::Var]
                if {$var eq ""} { incr i } else { lappend parts $var }
            }
            set start $i
        } else {
            if {$ch eq "\n"} { incr ln }
            incr i
        }
    }
    if {$i > $start} {
        lappend parts [list esc [string byterange $s $start $i-1]]
    }
    return $parts
}

# ---- Helpers over parsed words ----

# Is the word's value known without evaluating anything?
proc tp::isStatic {word} {
    if {[dict get $word expand]} { return 0 }
    foreach part [dict get $word parts] {
        if {[lindex $part 0] ni {str esc}} { return 0 }
    }
    return 1
}

# The value of a static word.
proc tp::value {word} {
    set value ""
    foreach part [dict get $word parts] {
        lassign $part type text
        if {$type eq "esc" && [string first "\\" $text] >= 0} {
            append value [subst -nocommands -novariables $text]
        } else {
            append value $text
        }
    }
    return $value
}

# Source-like rendering of a word, for reports.
proc tp::render {word} {
    set out [expr {[dict get $word expand] ? "{*}" : ""}]
    foreach part [dict get $word parts] {
        lassign $part type text
        switch $type {
            str { append out "{$text}" }
            esc { append out $text }
            var { append out "\$$text" }
            dictsugar { append out "\$$text" }
            exprsugar { append out "\$$text" }
            cmd { append out "\[$text\]" }
        }
    }
    return $out
}
