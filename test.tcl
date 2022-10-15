set n 100

Assert George is a dog
Assert when /name/ is a /animal/ {
    puts "  Found an animal $name"
}
Assert when /node/ has step count /c/ {}
Assert Bob is a cat

puts "$::nodename: No additional statements:"
puts "  [time Step $n]"

for {set i 0} {$i < 100} {incr i} { Assert $i }
puts "$::nodename: Asserted 100 statements:"
puts "  [time Step $n]"

Assert Omar is a human
puts "$::nodename: Asserted 100 statements + Omar is a human:"
puts "  [time Step $n]"

puts "$::nodename: Same:"
puts "  [time Step $n]"

puts "$::nodename: Same:"
puts "  [time Step $n]"

puts "$::nodename: Same:"
puts "  [time Step $n]"
