
package require tcc4tcl
set handle [tcc4tcl::new]
$handle process_command_line {-D__ARM_PCS_VFP=1}

$handle cproc test {int i} int { return (i+43); }
puts [$handle code]
$handle go

puts [test 1]
