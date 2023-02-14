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
    foreach procName [info procs ::SerializableEnvironment::*] {
        dict set env ^[namespace tail $procName] \
            [list [info args $procName] [info body $procName]]
    }
    foreach importName [namespace eval ::SerializableEnvironment {namespace import}] {
        dict set env %$importName [namespace origin ::SerializableEnvironment::$importName]
    }
    set env
}

proc runInSerializedEnvironment {body env} {
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
    if {[catch {namespace eval ::SerializableEnvironment $body} err] == 1} {
        puts "$::nodename: Error: $err\n$::errorInfo"
    }
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
