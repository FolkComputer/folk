set points [list [list 0 0]]
set r [region create_convex_region $points [llength $points]]
region pprint $r

set points [list [list 0 0] [list 1 0]]
set r [region create_convex_region $points [llength $points]]
region pprint $r

set points [list [list 0 0] [list 1 0] [list 0 1]]
set r [region create_convex_region $points [llength $points]]
region pprint $r

set points [list [list 0 0] [list 1 0] [list 1 1] [list 0 1]]
set r [region create_convex_region $points [llength $points]]
region pprint $r

puts [region to_tcl $r]
