namespace eval Hello {
    variable cc [c create]
    $cc proc sayhelloworld {} void {
        printf("Hello, world!\n");
    }
    $cc compile
}

namespace eval DoStuff {
    variable cc [c create]
    $cc import ::Hello::cc sayhelloworld as ok
    $cc proc dostuff {} void {
        ok();
    }
    $cc compile
}

DoStuff::dostuff
