source "folk.tcl"
package require Tk

text .t
pack .t -expand true -fill both

# periodically request samples
# connect to the peer
# set chan [socket folk.local 4273]
# puts "got [gets $chan]"
# close $chan

.t insert end {blah blah blah}
