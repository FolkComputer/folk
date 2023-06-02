set ::processPrelude {
    if {[info exists ::entry]} {
      return; # don't run if we're in the main process
    }

    source "main.tcl"
    proc every {ms body} {
        try $body
        after $ms [list after idle [namespace code [info level 0]]]
    }

    Assert $::nodename wishes $::nodename shares all claims
    Assert $::nodename wishes $::nodename shares statements like \
        [list /someone/ wishes $::nodename receives statements like /pattern/]

    source "lib/peer.tcl"
    ::peer "localhost"
}

proc On-process {name body} {
    namespace eval ::Processes::$name {}
    set ::Processes::${name}::name $name
    set ::Processes::${name}::body $body
    set ::Processes::${name}::this [uplevel {expr {[info exists this] ? $this : "<unknown>"}}]
    namespace eval ::Processes::$name {
        variable tclfd [file tempfile tclfile tclfile.tcl]
        set body [format {
            Assert <process.tcl> claims <root> has program code {%s}
            Step
            vwait forever
        } $body]
        puts $tclfd [join [list $::processPrelude $body] "\n"]; close $tclfd

        # TODO: send it the serialized environment
        variable stdout_reader; variable stdout_writer
        lassign [chan pipe] stdout_reader stdout_writer

        set pid [exec tclsh8.6 $tclfile >@ $stdout_writer 2>@ $stdout_writer &]

        variable log [list]
        proc handleReadable {} {
            variable name
            variable log
            if {[gets $stdout_reader line] >= 0} {
                lappend log $line
                puts "$name: $line **"
                Retract process $name has standard output log /l/
                Assert process $name has standard output log $log
                Step
            } elseif {[eof $stdout_reader]} { 
              close $stdout_reader
            }
        }
        # fconfigure $stdio -blocking 0 -buffering line
        fconfigure $stdout_reader -blocking 0 -buffering line
        fileevent $stdout_reader readable [namespace code handleReadable]

        if {$this ne "<unknown>"} {
            Assert $this is running process $name
        }

        proc handleUnmatch {} {
            variable pid
            variable name
            variable stdout_reader
            close $stdout_reader
            exec kill -9 $pid 
            while {1} {
              try {
                exec kill -0 $pid
              } on error err {
                break
              }
              puts "waiting for unmatch kill to work"
            }
            Retract /someone/ is running process $name
            Retract process $name has standard output log /something/
            namespace delete ::Processes::$name
        }
        uplevel 2 [list On unmatch ::Processes::${name}::handleUnmatch]
    }
}
