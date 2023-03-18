proc parse_json {json} {
    set result [dict create]

    # Remove leading and trailing spaces, and the opening and closing curly braces
    set json [string trim $json]
    set json [string range $json 1 end-1]

    # Split the JSON string into key-value pairs
    set pairs [regexp -all -inline -- {[^,]*:[^,]*} $json]

    foreach pair $pairs {
        # Split the key and value by the colon
        set key_value [split $pair ":"]
        set key [string trim [lindex $key_value 0]]
        set value [string trim [lindex $key_value 1]]

        # Remove quotes around the key and value (if applicable)
        set key [string map {\" {}} $key]
        set value [string map {\" {}} $value]

        # Convert "true" and "false" strings to boolean values
        if {$value eq "true"} {
            set value 1
        } elseif {$value eq "false"} {
            set value 0
        }

        # Add the key-value pair to the result dictionary
        dict set result $key $value
    }

    return $result
}

# Test the JSON parsing
set json_string {"name": "John Doe", "age": 30, "isStudent": false}
set tcl_dict [parse_json $json_string]
puts $tcl_dict
