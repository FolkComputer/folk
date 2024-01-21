source "lib/c.tcl"
source "trie.tcl"

set cc [c create]
$cc cflags -I. trie.c db.c
$cc include <stdlib.h>
$cc include "db.h"
$cc proc dbTest {} Trie* {
    testInit();
    testAssert(clause("This", "is", "a", "thing", 0));
    testAssert(clause("This", "is", "a", "thing", 0));
    testAssert(clause("This", "is", "another", "thing", 0));

    return testGetClauseToStatementId();
}
try {
    $cc compile
} on error e { puts stderr $e }

if {[info exists ::argv0] && $::argv0 eq [info script]} {
    trieWriteToPdf [dbTest] db.pdf
    puts db.pdf
}
