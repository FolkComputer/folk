package require critcl

namespace eval ctrie {
    namespace export moo
    critcl::cproc moo {} int {
        return 3;
    }
    critcl::load
    namespace ensemble create
}

puts [ctrie moo]
