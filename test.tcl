Assert George is a dog
Assert when /name/ is a /animal/ {
    puts "  Found an animal $name"
}
Assert when /node/ has step count /c/ {}
Assert Bob is a cat

puts "$::nodename: No additional statements:"
puts "  [time Step 50]"

for {set i 0} {$i < 100} {incr i} { Assert $i }
puts "$::nodename: Asserted 100 statements:"
puts "  [time Step 50]"

Assert Omar is a human
puts "$::nodename: Asserted 100 statements + Omar is a human:"
puts "  [time Step 50]"

puts "$::nodename: Same:"
puts "  [time Step 50]"

puts "$::nodename: Same:"
puts "  [time Step 50]"
