package require Thread

set ::cstuff {
    package require critcl

    critcl::ccode {
        char* str = "Not";
    }
    critcl::cproc init {} void {
        str = "Initialized";
    }
    critcl::cproc prn {} void {
        printf("[%s]\n", str);
    }
}

eval $::cstuff
init

proc spawn {} {
    thread::create [format {
        catch {
            puts [time {%s} 1]
            puts "Hello from thread."
            prn
            puts "Done."
        } err
        puts $err
    } $::cstuff]
}

after 1000 {spawn}
after 5000 {spawn}

vwait forever
