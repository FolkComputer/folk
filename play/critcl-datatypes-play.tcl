package require critcl

critcl::ccode {
    typedef struct str {
        char[10] s;
    } str_t;
}
critcl::cproc mallocate {} void* {
    str_t *str = malloc(sizeof(str));
    str.s = "hello!";
    return str;
}

puts [mallocate]
