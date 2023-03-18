# Calculates a Bezier curve with the specified control points
proc bezier {points {stepSize 0.01}} {
  set n [expr {[llength $points] - 1}]
  set curve [list]

  for {set t 0.0} {$t <= 1.0} {set t [expr {$t + $stepSize}]} {
    set x 0.0
    set y 0.0
    for {set i 0} {$i <= $n} {incr i} {
      set coeff [expr {pow(1 - $t, $n - $i) * pow($t, $i) * [binomial $n $i]}]
      set x [expr {$x + $coeff * [lindex [lindex $points $i] 0]}]
      set y [expr {$y + $coeff * [lindex [lindex $points $i] 1]}]
    }
    lappend curve [list $x $y]
  }

  return $curve
}

# Returns the binomial coefficient of n and k
proc binomial {n k} {
  if {$k == 0 || $k == $n} {
    return 1
  } elseif {$k < 0 || $k > $n} {
    return 0
  } else {
    set a [binomial [expr {$n - 1}] [expr {$k - 1}]]
    set b [binomial [expr {$n - 1}] $k]
    return [expr {$a + $b}]
  }
}

puts [bezier {{0 0} {50 100} {100 0}}]