proc run {} {
    list [time Step 100] "[Statements::size] statements"
}

Assert George is a dog
Assert when /name/ is a /animal/ {{name animal} {
    puts "  Found an animal $name"
}}
Assert when /node/ has step count /c/ {{node c} {}}
Assert Bob is a cat

puts "$::thisProcess: No additional statements:"
puts "  [run]"

for {set i 0} {$i < 100} {incr i} { Assert $i }
puts "$::thisProcess: Asserted 100 statements:"
puts "  [run]"

Assert Omar is a human
puts "$::thisProcess: Asserted 100 statements + Omar is a human:"
puts "  [run]"

puts "$::thisProcess: Same:"
puts "  [run]"

puts "$::thisProcess: Same:"
puts "  [run]"

puts "$::thisProcess: Same:"
puts "  [run]"
