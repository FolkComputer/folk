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
# Test autocasting of Person to Person*.
$cc proc getFirstFromPointer {Person* p} char* {
    return p->name.first;
}
$cc proc plural {int npersons Person[] persons} void {}
$cc compile

puts [omar]
assert {[getFirstFromPointer [omar]] eq "Omar"}
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

set cc [c create]
$cc proc getthree {} {int[3]} {
    int* x = ckalloc(sizeof(int) * 3);
    x[0] = 10;
    x[1] = 20;
    x[2] = 30;
    return x;
}
$cc compile
assert {[getthree] eq {10 20 30}}

return

set cc [c create]
$cc struct Tag { double corners[4][2]; }
$cc compile

