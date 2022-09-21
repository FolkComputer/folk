set ::statements [dict create \
                      [list the time is 3] true \
                      [list when the time is /t/ { puts $t }] true ]
puts "statements: $::statements"

proc unify {a b} {
    if {[llength $a] != [llength $b]} { return false }

    set match [dict create]
    for {set i 0} {$i < [llength $a]} {incr i} {
        set aWord [lindex $a $i]
        set bWord [lindex $b $i]
        if {[regexp {^/([^/]+)/$} $aWord -> aVarName]} {
            dict set match $aVarName $bWord
        } elseif {[regexp {^/([^/]+)/$} $bWord -> bVarName]} {
            dict set match $bVarName $aWord
        } elseif {$aWord != $bWord} {
            return false
        }
    }
    return $match
}
proc matchAgainstExistingStatements {pattern} {
    set matches [list]
    dict for {stmt _} $::statements {
        set match [unify $pattern $stmt]
        if {$match != false} {
            lappend matches $match
        }
    }
    return $matches
}

proc whenize {pattern} {
    return [list when {*}$pattern /__body/]
}
proc unwhenize {pattern} {
    return [lreplace [lreplace $pattern end end] 0 0]
}

proc assertEq {a b} {
   if {$a != $b} {
       return -code error "assertion failed: {$a} == {$b}"
   }
}

assertEq [matchAgainstExistingStatements [list the time is 3]] {{}}
assertEq [matchAgainstExistingStatements [list the time is]] {}
assertEq [matchAgainstExistingStatements [list the time is /t/]] {{t 3}}

assertEq [unwhenize [whenize {the time is /t/}]] {the time is /t/}

assertEq [matchAgainstExistingStatements [unwhenize [list when the time is /t/ {puts $t}]]] {{t 3}}
assertEq [matchAgainstExistingStatements [whenize {the time is 10}]] {{t 10 __body { puts $t }}}

# question: is set-set match more efficient or 1-at-a-time match?
# probably 1-at-a-time match is fine
      
