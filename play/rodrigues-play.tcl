source "lib/language.tcl"
lappend auto_path ./vendor
package require math::linearalgebra
namespace import ::math::linearalgebra::*

# From https://courses.cs.duke.edu/cps274/fall13/notes/rodrigues.pdf:
proc rotationMatrixToRotationVector {R} {
    set A [scale 0.5 [sub $R [transpose $R]]]
    set rho [list [getelem $R 2 1] \
                 [getelem $R 0 2] \
                 [getelem $R 1 0]]
    set s [norm $rho]
    set c [expr {([getelem $R 0 0] + [getelem $R 1 1] + [getelem $R 2 2] - 1) / 2}]

    # If s = 0 and c = 1:
    if {abs($s) < 0.0001 && abs($c - 1) < 0.0001} {
        return {0 0 0}
    }
    # If s = 0 and c = -1:
    if {abs($s) < 0.0001 && abs($c - (-1)) < 0.0001} {
        # let v = a nonzero column of R + I
        set v [getcol [add $R [mkIdentity 3]] 0]
        set u [scale [/ 1.0 [norm $v]] $v]
        set r [scale 3.14159 $u]
        if {abs([norm $r] - 3.14159) < 0.0001 &&
            ((abs([getelem $r 0]) < 0.0001 &&
              abs([getelem $r 1]) < 0.0001 &&
              [getelem $r 2] < 0) ||
             (abs([getelem $r 0]) < 0.0001 &&
              [getelem $r 1] < 0) ||
             ([getelem $r 0] < 0))} {
            return [scale -1 $r]
        } else {
            return $r
        }
    }

    set u [scale [/ 1.0 $s] $rho]
    set theta [atan2 $s $c]
    return [scale $theta $u]
}

proc rotationVectorToRotationMatrix {r} {
    set theta [norm $r]
    if {abs($theta) < 0.0001} {
        return [mkIdentity 3]
    }
    set u [scale [/ 1.0 $theta] $r]
    set ux [list [list 0                       [* -1.0 [getelem $u 2]] [getelem $u 1]] \
                 [list [getelem $u 2]          0                       [* -1.0 [getelem $u 0]]] \
                 [list [* -1.0 [getelem $u 1]] [getelem $u 0]          0]]
    return [add [scale [cos $theta] [mkIdentity 3]] \
                [add [scale [expr {1.0 - cos($theta)}] \
                          [matmul $u [transpose $u]]] \
                     [scale [sin $theta] $ux]]]
}

proc yaw {theta} { subst {
    {[cos $theta] [- [sin $theta]] 0}
    {[sin $theta] [cos $theta] 0}
    {0 0 1}
} }
proc pitch {theta} { subst {
    {[cos $theta] 0 [sin $theta]}
    {0 1 0}
    {[- [sin $theta]] 0 [cos $theta]}
} }
proc roll {theta} { subst {
    {1 0 0}
    {0 [cos $theta] [- [sin $theta]]}
    {0 [sin $theta] [cos $theta]}
} }

proc testMatrix {R} {
    puts "=========="
    puts "$R:"
    set R [eval $R]
    puts [show $R]
    puts [show [rotationMatrixToRotationVector $R]]
    puts [show [rotationVectorToRotationMatrix [rotationMatrixToRotationVector $R]]]
}
testMatrix {roll 3.1}
testMatrix {pitch 3.1}
testMatrix {yaw 3.1}
testMatrix {list \
    {0.96608673169969	-0.25800404198456	-0.01050433974302} \
    {0.25673182392846	0.95537412871306	0.14611312318926} \
    {-0.02766220194012	-0.14385474794174	0.98921211783846}
}
