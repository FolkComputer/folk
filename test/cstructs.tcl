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
