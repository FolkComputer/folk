# can i compile some critcl code, then run it, then compile some more

package require critcl

critcl::ccode {
    char* byes = "bye\n";
}

critcl::cproc hello {} void {
    printf("hello\n");
}
hello

critcl::cproc bye {} void {
    printf(byes);
}
bye
