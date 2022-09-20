set ::statements [dict create \
                      [list the time is 3] true \
                      [list when the time is /t/ { puts t }] true ]
puts $::statements

proc matchAgainstExistingStatements {clause} {
    dict for {stmt _} $::statements {
        set match [matches $clause $stmt]
        
    }
}

proc whenize {clause} {

}
proc unwhenize {clause} {

}

puts [matchAgainstExistingStatements [list the time is 3]]
puts [matchAgainstExistingStatements [list the time is /t/]]
puts [matchAgainstExistingStatements [list the time is /t/]]

# question: is set-set match more efficient or 1-at-a-time match?
# probably 1-at-a-time match is fine
      
