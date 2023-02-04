proc assert condition {
   set s "{$condition}"
   if {![uplevel 1 expr $s]} {
       return -code error "assertion failed: $condition"
   }
}

set cc [c create]
$cc struct Name {
    char* first;
    char* last;
}
$cc struct Person {
    Name name;
    char* state;
}
$cc proc omar {} Person {
    Person ret = (Person) {
        .name = (Name) { .first = "Omar", .last = "Rizwan" },
        .state = "NJ"
    };
    return ret;
}
$cc compile

puts [omar]
assert {[dict get [omar] name last] eq "Rizwan"}
