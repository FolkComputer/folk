package require Thread

set th [thread::create {
    package require critcl
    critcl::cproc cspin {} void {
        printf("cstart\n");
        while (1) {}
        printf("cend\n");
    }
    proc tclspin {} {
        while 1 {}
    }

    puts tclstart
    catch {cspin} ;# can't cancel from in here
    # catch {tclspin}
    puts tclend
}]

puts $th
after 2000 {
    puts canceling
    thread::cancel $th
}

vwait forever
