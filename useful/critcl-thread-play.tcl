package require Thread

set cstuff {
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

eval $cstuff
init

thread::create [format {
    catch {
        %s
        puts "Hello from thread."
        prn
        puts "Done."
    } err
    puts $err
} $cstuff]

vwait forever
