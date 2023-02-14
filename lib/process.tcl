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
    set stdio [open "|tclsh8.6 $tclfile 2>@1" w+]
    set pid [pid $stdio]

    set ::processlog$pid [list]
    proc ::rl {pid name stdio} {
        if {[gets $stdio line] >= 0} {
            lappend ::processlog$pid $line
            Retract process $name has standard output log /l/
            Assert process $name has standard output log [set ::processlog$pid]
            Step
        } elseif {[eof $stdio]} { close $stdio }
    }
    fconfigure $stdio -blocking 0 -buffering line
    fileevent $stdio readable [list ::rl $pid $name $stdio]

    upvar this this
    if {[info exists this]} {
        Assert $this is running process $name
    }

    proc ::processunmatch {pid name} {
        exec kill $pid
        Retract /someone/ is running process $name
        Retract process $name has standard output log /something/
    }
    On unmatch [list ::processunmatch $pid $name]
}
