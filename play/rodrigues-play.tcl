source "lib/language.tcl"
lappend auto_path ./vendor
package require math::linearalgebra
namespace import ::math::linearalgebra::*

# From https://courses.cs.duke.edu/cps274/fall13/notes/rodrigues.pdf:
proc rotationMatrixToRotationVector {R} {
    set A [scale 0.5 [sub $R [transpose $R]]]
    set rho [list [getelem $A 2 1] \
                 [getelem $A 0 2] \
                 [getelem $A 1 0]]
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

source "lib/c.tcl"
set cc [c create]
$cc include <math.h>
$cc include <string.h>
$cc code {
    void rotationVectorToRotationMatrix(double r[3], double out[3][3]) {
        double theta = sqrt(r[0]*r[0] + r[1]*r[1] + r[2]*r[2]);
        if (fabs(theta) < 0.0001) {
            out = (double[3][3]) {
                {1, 0, 0},
                {0, 1, 0},
                {0, 0, 1}
            };
        }
        double u[3] = {r[0]/theta, r[1]/theta, r[2]/theta};
        double ret[3][3] = {
            {cos(theta) + u[0]*u[0]*(1 - cos(theta)),        u[0]*u[1]*(1 - cos(theta)) - u[2]*sin(theta),     u[0]*u[2]*(1 - cos(theta)) + u[1]*sin(theta)},
            {u[0]*u[1]*(1 - cos(theta)) + u[2]*sin(theta),   cos(theta) + u[1]*u[1]*(1 - cos(theta)),          u[1]*u[2]*(1 - cos(theta)) - u[0]*sin(theta)},
            {u[0]*u[2]*(1 - cos(theta)) - u[1]*sin(theta),   u[1]*u[2]*(1 - cos(theta)) + u[0]*sin(theta),     cos(theta) + u[2]*u[2]*(1 - cos(theta))}
        };
        memcpy(out, ret, sizeof(ret));
    }
}
$cc proc cRotationVectorToRotationMatrix {double[3] r} Tcl_Obj* {
    double out[3][3]; rotationVectorToRotationMatrix(r, out);
    return Tcl_ObjPrintf("{%f %f %f}\n{%f %f %f}\n{%f %f %f}",
                         out[0][0], out[0][1], out[0][2],
                         out[1][0], out[1][1], out[1][2],
                         out[2][0], out[2][1], out[2][2]);
}
$cc compile

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
    set r [rotationMatrixToRotationVector $R]
    puts "r (magnitude [norm $r]):"
    puts [show $r]
    puts "reconverted to R via Tcl:"
    puts [show [rotationVectorToRotationMatrix [rotationMatrixToRotationVector $R]]]
    puts "reconverted to R via C:"
    puts [show [cRotationVectorToRotationMatrix [rotationMatrixToRotationVector $R]]]
}
testMatrix {roll 1.1}
testMatrix {pitch 1.1}
testMatrix {yaw 1.1}
testMatrix {matmul [yaw 1.1] [pitch 1.1]}
testMatrix {list \
    {0.96608673169969	-0.25800404198456	-0.01050433974302} \
    {0.25673182392846	0.95537412871306	0.14611312318926} \
    {-0.02766220194012	-0.14385474794174	0.98921211783846}
}
