set points [list [list 0 0] [list 1 1]]
set r [region create_region $points [llength $points]]
region puts_region $r
