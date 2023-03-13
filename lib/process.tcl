set ::processPrelude {
    source "main.tcl"
    proc every {ms body} {
        try $body
        after $ms [list after idle [namespace code [info level 0]]]
    }

    Assert $::nodename wishes $::nodename shares all statements

    source "lib/peer.tcl"
    peer "localhost"
    vwait Peers::localhost::connected
}

proc On-process {name body} {
    namespace eval ::Processes::$name {}
    set ::Processes::${name}::name $name
    set ::Processes::${name}::body $body
    set ::Processes::${name}::this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]
    namespace eval ::Processes::$name {
        variable tclfd [file tempfile tclfile tclfile.tcl]
        puts $tclfd [join [list $::processPrelude $body] "\n"]; close $tclfd

        # TODO: send it the serialized environment
        variable stdio [open "|tclsh8.6 $tclfile 2>@1" w+]
        variable pid [pid $stdio]

        variable log [list]
        proc handleReadable {} {
            variable name
            variable stdio
            variable log
            if {[gets $stdio line] >= 0} {
                lappend log $line
                puts "$name: $line"
                Retract process $name has standard output log /l/
                Assert process $name has standard output log $log
                Step
            } elseif {[eof $stdio]} { close $stdio }
        }
        fconfigure $stdio -blocking 0 -buffering line
        fileevent $stdio readable [namespace code handleReadable]

        if {$this ne "<unknown>"} {
            Assert $this is running process $name
        }

        proc handleUnmatch {} {
            variable pid
            variable name
            catch {exec kill $pid}
            Retract /someone/ is running process $name
            Retract process $name has standard output log /something/
            namespace delete ::Processes::$name
        }
        On unmatch [namespace code handleUnmatch]
    }
}
