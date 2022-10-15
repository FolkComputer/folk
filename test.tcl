proc run {} {
    list [time Step 100] "[Statements::size] statements"
}

Assert George is a dog
Assert when /name/ is a /animal/ {
    puts "  Found an animal $name"
}
Assert when /node/ has step count /c/ {}
Assert Bob is a cat

puts "$::nodename: No additional statements:"
puts "  [run]"

for {set i 0} {$i < 100} {incr i} { Assert $i }
puts "$::nodename: Asserted 100 statements:"
puts "  [run]"

Assert Omar is a human
puts "$::nodename: Asserted 100 statements + Omar is a human:"
puts "  [run]"

puts "$::nodename: Same:"
puts "  [run]"

puts "$::nodename: Same:"
puts "  [run]"

puts "$::nodename: Same:"
puts "  [run]"
