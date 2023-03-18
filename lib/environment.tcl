namespace eval ::SerializableEnvironment {}

proc serializeEnvironment {} {
    set env [dict create]
    # get all variables and serialize them
    # (to fake lexical scope)
    foreach name [info vars ::SerializableEnvironment::*] {
        if {![string match "::SerializableEnvironment::__*" $name]} {
            dict set env [namespace tail $name] [set $name]
        }
    }
    foreach importName [namespace eval ::SerializableEnvironment {namespace import}] {
        dict set env %$importName [namespace origin ::SerializableEnvironment::$importName]
    }
    foreach procName [info procs ::SerializableEnvironment::*] {
        if {![dict exists $env %[namespace tail $procName]]} {
            dict set env ^[namespace tail $procName] \
                [list [info args $procName] [info body $procName]]
        }
    }
    set env
}

proc deserializeEnvironment {env} {
    dict for {name value} $env {
        if {[string index $name 0] eq "^"} {
            proc ::SerializableEnvironment::[string range $name 1 end] {*}$value
        } elseif {[string index $name 0] eq "%"} {
            namespace eval ::SerializableEnvironment \
                [list namespace import -force $value]
        } else {
            set ::SerializableEnvironment::$name $value
        }
    }
}

proc isRunningInSerializedEnvironment {} {
    expr {[uplevel {namespace current}] eq "::SerializableEnvironment"}
}
proc runInSerializedEnvironment {body env} {
    deserializeEnvironment $env
    try {
        namespace eval ::SerializableEnvironment $body
    } finally {
        # Clean up:
        foreach procName [info procs ::SerializableEnvironment::*] {
            rename $procName ""
        }
        foreach name [info vars ::SerializableEnvironment::*] {
            unset $name
        }
        namespace eval ::SerializableEnvironment {
            namespace forget {*}[namespace import]
        }
    }
}
