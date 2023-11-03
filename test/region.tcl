puts [region convexHull [list]]

set points [list [list 0 0]]
puts [region convexHull $points]

set points [list [list 0 0] [list 1 0]]
puts [region convexHull $points]

set points [list [list 0 0] [list 1 0] [list 0 1]]
puts [region convexHull $points]

set points [list [list 0.5 0] [list 1.2 0] [list 1 1] [list 0 1]]
puts [region convexHull $points]
