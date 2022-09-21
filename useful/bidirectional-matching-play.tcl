set ::statements [dict create \
                      [list the time is 3] true \
                      [list when the time is /t/ { puts t }] true ]
puts "statements: $::statements"

proc matchPattern {pattern statement} {
    set match [dict create]
    for {set i 0} {$i < [llength $pattern]} {incr i} {
        set patternWord [lindex $pattern $i]
        set statementWord [lindex $statement $i]
        if {[regexp {^/([^/]+)/$} $patternWord -> patternVarName]} {
            dict set match $patternVarName $statementWord
        } elseif {$patternWord != $statementWord} {
            return false
        }
    }
    return $match
}
proc matchAgainstExistingStatements {pattern} {
    set matches [list]
    dict for {stmt _} $::statements {
        set match [matchPattern $pattern $stmt]
        if {$match != false} {
            lappend matches $match
        }
    }
    return $matches
}

proc whenize {pattern} {
    return [list when {*}$pattern /body/]
}
proc unwhenize {pattern} {
    return [lreplace [lreplace $pattern end end] 0 0]
}

puts [matchAgainstExistingStatements [list the time is 3]]
puts [matchAgainstExistingStatements [list the time is /t/]]
puts [matchAgainstExistingStatements [list the time is /t/]]

# question: is set-set match more efficient or 1-at-a-time match?
# probably 1-at-a-time match is fine
      
