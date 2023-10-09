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
$cc proc plural {int npersons Person[] persons} void {}
$cc compile

puts [omar]
assert {[dict get [omar] name last] eq "Rizwan"}

plural 2 [list \
              [dict create name [dict create first Omar last Rizwan] state NJ] \
              [dict create name [dict create first Californian last Resident] state CA]]

set cc [c create]
$cc proc plusone {int a} int {
    return a + 1;
}
$cc proc dostuff {void* v} int {
    return 300;
}
$cc compile
assert {[plusone 3] eq 4}

catch {plusone Wrong} err
assert {[string match {expected integer but got "Wrong"*} $err]}

catch {dostuff hi} err
assert {[string match {failed to convert argument from Tcl to C*} $err]}
