Assert C is a programming language
Assert Java is a programming language
Assert JavaScript is a programming language
Assert /someone/ wishes to run program {
    Claim Mac is an OS
    Claim Linux is an OS
    Claim Windows is an OS

    When /x/ is an OS {
        sleep 3
        Claim $x really is an OS
    }

    When Mac really is an OS \&
         Linux really is an OS \&
         Windows really is an OS {
        puts "Passed"
        exit 0
    }
}

# TODO: Implement Assert, Claim, When
