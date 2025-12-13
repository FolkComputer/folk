lassign [pipe] ch_read ch_read2
lassign [pipe] ch_write2 ch_write
set python_pid [exec python3 -i <@$ch_write2 >@$ch_read2 &]
close $ch_read2
close $ch_write2

fconfigure $ch_write -buffering line
fconfigure $ch_read -buffering line

proc eval_python {write_handle read_handle command} {
    puts $write_handle $command
    flush $write_handle
    
    set result [gets $read_handle]
    return $result
}

puts "Evaluating: 2 + 3"
set result1 [eval_python $ch_write $ch_read "print(2 + 3)"]
puts "Result: $result1"

puts "Evaluating: 2 * 10"
set result2 [eval_python $ch_write $ch_read "print(2 * 10)"]
puts "Result: $result2"

puts $ch_write "exit()"
close $ch_write
close $ch_read

puts "Done!"
