package require tcc4tcl
set handle [tcc4tcl::new]
$handle process_command_line {-D__ARM_PCS_VFP=1}

$handle cproc test {} void* {
    char* hello = "Hello\n";
    return hello;
}
$handle cproc prn {void* p} void {
    printf("string [%s]\n", p);
}
$handle go

prn [test]
