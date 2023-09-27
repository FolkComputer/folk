# 'Language' utilities that extend and customize base Tcl.

proc fn {name argNames body} {
    uplevel [list set ^$name [list $argNames $body]]
}
rename unknown _original_unknown
# Trap resolution of commands so that they can call the lambda in
# lexical scope created by `fn`.
proc unknown {name args} {
    if {[uplevel [list info exists ^$name]]} {
        apply [uplevel [list set ^$name]] {*}$args
    } else {
        uplevel [list _original_unknown $name {*}$args]
    }
}

# Trim indentation in multiline quoted text.
proc undent {msg {whitespaceChars " "}} {
    set msgLines [split $msg "\n"]
    set maxLength [string length $msg]

    set regExp [subst -nocommands {([$whitespaceChars]*)[^$whitespaceChars]}]

    set indent [
        tcl::mathfunc::min {*}[
            lmap x $msgLines {
                if {[regexp $regExp $x match whitespace]} {
                    string length $whitespace
                } else {
                    lindex $maxLength
                }
            }
        ]
    ]

    join [ltrim [lmap x $msgLines {string range $x $indent end}]] "\n"
}
# Remove empty items at the beginning and the end of a list.
proc ltrim {list} {
    set first [lsearch -not -exact $list {}]
    set last [lsearch -not -exact [lreverse $list] {}]
    return [
        if {$first == -1} {
            list
        } else {
            lrange $list $first end-$last
        }
    ]
}
proc lenumerate {l} {
    set ret [list]
    for {set i 0} {$i < [llength $l]} {incr i} {
        lappend ret $i [lindex $l $i]
    }
    set ret
}

proc python3 {args} {
    exec python3 << [undent [join $args " "]]
}

proc assert condition {
    set s "{$condition}"
    if {![uplevel 1 expr $s]} {
        set errmsg "assertion failed: $condition"
        try {
            if {[lindex $condition 1] eq "eq" && [string index [lindex $condition 0] 0] eq "$"} {
                set errmsg "$errmsg\n[uplevel 1 [list set [string range [lindex $condition 0] 1 end]]] is not equal to [lindex $condition 2]"
            }
        } on error e {}
        return -code error $errmsg
    }
}

proc baretime body { string map {" microseconds per iteration" ""} [uplevel [list time $body]] }

# forever { ... } is sort of like while true { ... }, but it yields to
# the event loop after each iteration.
proc forever {body} {
    while true {
        uplevel $body
        update
    }
}

namespace import ::tcl::mathop::*
namespace import ::tcl::mathfunc::*

