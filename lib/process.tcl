proc On-process {name body} {
    set tclfd [file tempfile tclfile tclfile.tcl]
    puts $tclfd [join [list {
        source "main.tcl"
        proc every {ms body} {
            try $body
            after $ms [list after idle [namespace code [info level 0]]]
        }
    } $body] "\n"]; close $tclfd

    # TODO: send it the serialized environment
    # TODO: establish I/O w/o stdout/stdin
    set stdio [open "|tclsh8.6 $tclfile 2>@stderr" w+]
    set pid $stdio

    set ::onScript$pid ""
    proc ::rl {pid stdio} {
        if {[gets $stdio line] >= 0} {
            append ::onScript$pid $line
            if {[info complete [set ::onScript$pid]]} {
                puts $stdio [eval [set ::onScript$pid]]
                set ::onScript$pid ""
            }
        } elseif {[eof $stdio]} { close $stdio }
    }
    fconfigure $stdio -blocking 0 -buffering line
    fileevent $stdio readable [list ::rl $pid $stdio]

    On unmatch [list exec kill $pid]
}
