namespace eval Evaluator { source "lib/environment.tcl" }
source "lib/language.tcl"
source "lib/c.tcl"

lappend auto_path "./vendor"
package require math::linearalgebra
rename ::scale scaleTk
namespace import ::math::linearalgebra::*

# Computes a 3x3 homography H from model to image.
proc findHomography {modelPoints imagePoints} {
    set ROWS 4
    set COLS 6

    set A [list]
    set b [list]
    foreach imagePoint $imagePoints modelPoint $modelPoints {
        lassign $imagePoint u v
        lassign $modelPoint x y
        lappend A [list $x $y 1 0  0  0 [expr {-$x*$u}] [expr {-$y*$u}]]
        lappend A [list 0  0  0 $x $y 1 [expr {-$x*$v}] [expr {-$y*$v}]]
        lappend b $u $v
    }

    lassign [leastSquaresSVD $A $b] a0 a1 a2 b0 b1 b2 c0 c1
    set H [subst {
        {$a0 $a1 $a2}
        {$b0 $b1 $b2}
        {$c0 $c1 1}
    }]

    return $H
}

proc processHomography {H} {
    fn h {i j} { getelem $H [- $j 1] [- $i 1] }

    fn v {i j} {
        list \
            [* [h $i 1] [h $j 1]] \
            [+ [* [h $i 1] [h $j 2]] [* [h $i 2] [h $j 1]]] \
            [* [h $i 2] [h $j 2]] \
            [+ [* [h $i 3] [h $j 1]] [* [h $i 1] [h $j 3]]] \
            [+ [* [h $i 3] [h $j 2]] [* [h $i 2] [h $j 3]]] \
            [* [h $i 3] [h $j 3]]
    }
    # TODO: How do I check v_{ij}?

    set V [list \
               [v 1 2] \
               [sub [v 1 1] [v 2 2]]]
    return $V
}

# Draw detections:
package require Tk

proc loadDetections {name sideLength detections} {
    set ROWS 4
    set COLS 6

    toplevel .$name
    puts "loadDetections $name"

    # Model points, from the known geometry of the checkerboard (in
    # meters, where top-left corner of top-left AprilTag is 0, 0).
    set modelPoints [list]
    for {set row 0} {$row < $ROWS} {incr row} {
        for {set col 0} {$col < $COLS} {incr col} {
            lappend modelPoints \
                [list [* $col $sideLength 2] \
                     [+ [* $row $sideLength 2] $sideLength]] ;# bottom-left
            
            lappend modelPoints \
                [list [+ [* $col $sideLength 2] $sideLength] \
                     [+ [* $row $sideLength 2] $sideLength]] ;# bottom-right

            lappend modelPoints \
                [list [+ [* $col $sideLength 2] $sideLength] \
                     [* $row $sideLength 2]] ;# top-right

            lappend modelPoints \
                [list [* $col $sideLength 2] [* $row $sideLength 2]] ;# top-left
        }
    }

    set imagePointsForDetection [list]
    proc detectionTagCorner {detection row col corner} {
        upvar COLS COLS
        set id [expr {48600 + $row*$COLS + $col}]
        return [lindex [dict get [dict get $detection $id] corners] $corner]
    }
    foreach detection $detections {
        # Camera points, from the camera image.
        set imagePoints [list]
        for {set row 0} {$row < $ROWS} {incr row} {
            for {set col 0} {$col < $COLS} {incr col} {
                lappend imagePoints [detectionTagCorner $detection $row $col 0]
                lappend imagePoints [detectionTagCorner $detection $row $col 1]
                lappend imagePoints [detectionTagCorner $detection $row $col 2]
                lappend imagePoints [detectionTagCorner $detection $row $col 3]
            }
        }
        lappend imagePointsForDetection $imagePoints
    }

    set Hs [lmap imagePoints $imagePointsForDetection {
        findHomography $modelPoints $imagePoints
    }]

    canvas .$name.canv -width 1280 -height 720 -background white
    set detectionButtons [lmap {i detection} [lenumerate $detections] {
        button .$name.detection$i -text detection$i -command [list apply {{name detection} {
            set ROWS 4
            set COLS 6

            .$name.canv delete all
            .$name.canv create rectangle 4 4 [- 1280 2] [- 720 2] -outline blue
            dict for {id tag} $detection {
                set corners [dict get $tag corners]
                .$name.canv create line {*}[join $corners] {*}[lindex $corners 0]
            }

            fn drawDetectionTagCorner {row col corner label} {
                .$name.canv create oval \
                    {*}[detectionTagCorner $detection $row $col $corner] \
                    {*}[add [detectionTagCorner $detection $row $col $corner] {5 5}] \
                    -fill red
                .$name.canv create text [detectionTagCorner $detection $row $col $corner] \
                    -text $label
            }

            drawDetectionTagCorner 0 0 3 TL
            drawDetectionTagCorner 0 [- $COLS 1] 2 TR
            drawDetectionTagCorner [- $ROWS 1] [- $COLS 1] 1 BR
            drawDetectionTagCorner [- $ROWS 1] 0 0 BL
        }} $name $detection]
    }]

    set homButtons [lmap {i H} [lenumerate $Hs] {
        button .$name.h$i -text H$i -command [list apply {{name sideLength detection H} {
            .$name.canv delete all
            .$name.canv create rectangle 4 4 [- 1280 2] [- 720 2] -outline red
            # Model points, from the known geometry of the checkerboard (in
            # meters, where top-left corner of top-left AprilTag is 0, 0).
            set ROWS 4
            set COLS 6
            for {set row 0} {$row < $ROWS} {incr row} {
                for {set col 0} {$col < $COLS} {incr col} {
                    set corners [list]
                    lappend corners [list [* $col $sideLength 2] \
                                       [+ [* $row $sideLength 2] $sideLength]] ;# bottom-left

                    lappend corners [list [+ [* $col $sideLength 2] $sideLength] \
                                       [+ [* $row $sideLength 2] $sideLength]] ;# bottom-right

                    lappend corners [list [+ [* $col $sideLength 2] $sideLength] \
                                       [* $row $sideLength 2]] ;# top-right

                    lappend corners [list [* $col $sideLength 2] [* $row $sideLength 2]] ;# top-left

                    set corners [lmap corner $corners {matmul $H [list {*}$corner 1]}]
                    set corners [lmap corner $corners {
                        lassign $corner cx cy cz
                        list [/ $cx $cz] [/ $cy $cz]
                    }]
                    .$name.canv create line {*}[join $corners] {*}[lindex $corners 0]
                }
            }
        }} $name $sideLength [lindex $detections $i] $H]
    }]
    pack .$name.canv {*}$detectionButtons {*}$homButtons -fill both -expand true

    # Try to solve for the camera intrinsics:
    try {
        # Construct V:
        set Vtop [list]; set Vbottom [list]
        foreach H $Hs {
            lassign [processHomography $H] Vtop_ Vbottom_
            lappend Vtop $Vtop_
            lappend Vbottom $Vbottom_
        }
        set V [list {*}$Vtop {*}$Vbottom]
        assert {[shape $V] eq [list [* 2 [llength $Hs]] 6]}

        # Solve Vb = 0:
        lassign [determineSVD [matmul [transpose $V] $V]] U S V'
        set b [lindex [transpose ${V'}] [lindex [lsort -real -indices $S] 0]]

        # Compute unrefined camera intrinsics:
        lassign $b B11 B12 B22 B13 B23 B33
        set v0 [expr {($B12*$B13 - $B11*$B23) / ($B11*$B22 - $B12*$B12)}]
        set lambda [expr {$B33 - ($B13*$B13 + $v0*($B12*$B13 - $B11*$B23))/$B11}]
        set alpha [expr {sqrt($lambda/$B11)}]
        set beta [expr {sqrt($lambda*$B11/($B11*$B22 - $B12*$B12))}]
        set gamma [expr {-$B12*$alpha*$alpha*$beta/$lambda}]
        set u0 [expr {$gamma*$v0/$beta - $B13*$alpha*$alpha/$lambda}]

        puts "Unrefined Camera Intrinsics:"
        puts "=============================="
        puts "   Focal Length: \[ $alpha $beta ]"
        puts "Principal Point: \[ $u0 $v0 ]"
        puts "           Skew: \[ $gamma ] "
        puts ""

        # Unrefined camera intrinsic matrix:
        set A [subst {
            {$alpha $gamma $u0}
            {     0  $beta $v0}
            {     0      0   1}
        }]

        # Compute extrinsics for each of the images (needed so we can
        # do the reprojection during nonlinear refinement)
        proc recoverExtrinsics {H A} {
            set h0 [getcol $H 0]
            set h1 [getcol $H 1]
            set h2 [getcol $H 2]

            set Ainv [solvePGauss $A [mkIdentity 3]]
            set lambda_ [/ 1.0 [norm [matmul $Ainv $h0]]]

            set r0 [scale $lambda_ [matmul $Ainv $h0]]
            set r1 [scale $lambda_ [matmul $Ainv $h1]]
            set r2 [crossproduct $r0 $r1]
            set t [scale $lambda_ [matmul $Ainv $h2]]

            set R [transpose [list $r0 $r1 $r2]]
            # Reorthogonalize R:
            lassign [determineSVD $R] U S V
            set R [matmul $U [transpose $V]]

            # Reconstitute full extrinsics:
            return [transpose [list {*}[transpose $R] $t]]
        }
        set Rs [lmap H $Hs {recoverExtrinsics $H $A}]

        set r0s [list]; set r1s [list]; set ts [list]
        foreach R $Rs {
            lappend r0s [getcol $R 0]
            lappend r1s [getcol $R 1]
            lappend ts [getcol $R 3]
        }

        # A is a 3x3 matrix, the intrinsics guess.
        # r0s, r1s, ts are lists of NUM_IMAGES r0, r1, t 3x1 vectors, the extrinsics guesses.
        proc reprojectionError {A r0s r1s ts} {
            upvar modelPoints modelPoints
            upvar imagePointsForDetection imagePointsForDetection

            set err 0
            foreach imagePoints $imagePointsForDetection r0 $r0s r1 $r1s t $ts {
                foreach modelPoint $modelPoints imagePoint $imagePoints {
                    # Reproject the model point to a reprojected image point.
                    set H [matmul $A [transpose [list $r0 $r1 $t]]]
                    lassign [matmul $H [list {*}$modelPoint 1]] rpx rpy rpz
                    set reprojectedImagePoint [list [/ $rpx $rpz] [/ $rpy $rpz]]

                    set localErr [norm [sub $imagePoint $reprojectedImagePoint]]
                    set err [+ $err $localErr]
                }
            }
            return $err
        }
        puts "Tcl reprojection error: [reprojectionError $A $r0s $r1s $ts]"

        proc pythonize {A} {
            string cat {[} [join [lmap row $A {string cat {[} [join $row ", "] {]}}] ", "] {]}
        }
        proc reprojectionErrorC {alpha gamma u0 beta v0 r0s r1s ts} {
            upvar modelPoints modelPoints
            upvar imagePointsForDetection imagePointsForDetection

            set cc [c create]
            $cc include <math.h>
            $cc include <string.h>
            $cc include <assert.h>
            $cc include "cmpfit/mpfit.h"
            $cc cflags ./vendor/cmpfit/mpfit.c
            $cc code [csubst {
                #define NUM_POINTS_IN_IMAGE $[llength $modelPoints]
                #define NUM_IMAGES $[llength $imagePointsForDetection]

                double Model[NUM_POINTS_IN_IMAGE][2];
                double Image[NUM_IMAGES][NUM_POINTS_IN_IMAGE][2];
            }]
            $cc proc setModel {double[] model} void {
                for (int i = 0; i < NUM_POINTS_IN_IMAGE; i++) {
                    Model[i][0] = model[i * 2 + 0];
                    Model[i][1] = model[i * 2 + 1];
                }
            }
            $cc proc setImage {double[] image} void {
                for (int imageNum = 0; imageNum < NUM_IMAGES; imageNum++) {
                    for (int i = 0; i < NUM_POINTS_IN_IMAGE; i++) {
                        int idx = imageNum * NUM_POINTS_IN_IMAGE * 2 + i * 2;
                        Image[imageNum][i][0] = image[idx];
                        Image[imageNum][i][1] = image[idx + 1];
                    }
                }
            }
            $cc code {
                void mulMat3Mat3(double A[3][3], double B[3][3], double out[3][3]) {
                    memset(out, 0, sizeof(double) * 9);
                    for (int y = 0; y < 3; y++) {
                        for (int x = 0; x < 3; x++) {
                            for (int k = 0; k < 3; k++) {
                                out[y][x] += A[y][k] * B[k][x];
                            }
                        }
                    }
                }
                void mulMat3Vec3(double A[3][3], double x[3], double out[3]) {
                    memset(out, 0, sizeof(double) * 3);
                    for (int y = 0; y < 3; y++) {
                        out[y] = A[y][0]*x[0] + A[y][1]*x[1] + A[y][2]*x[2];
                    }
                }
            }
            $cc proc func {int m int n double* x
                           double* fvec double** dvec
                           void* _} int {
                assert(m == NUM_POINTS_IN_IMAGE * NUM_IMAGES);

                // Unwrap the parameters x[]:
                int k = 0;

                double alpha = x[k++];
                double gamma = x[k++];
                double u0 = x[k++];
                double beta = x[k++];
                double v0 = x[k++];
                double A[3][3] = {
                    {alpha, gamma, u0},
                    {    0,  beta, v0},
                    {    0,     0,  1}
                };

                double r0s[NUM_IMAGES][3]; double r1s[NUM_IMAGES][3]; double ts[NUM_IMAGES][3];
                {
                    for (int imageNum = 0; imageNum < NUM_IMAGES; imageNum++) {
                        r0s[imageNum][0] = x[k++];
                        r0s[imageNum][1] = x[k++];
                        r0s[imageNum][2] = x[k++];
                    }
                    for (int imageNum = 0; imageNum < NUM_IMAGES; imageNum++) {
                        r1s[imageNum][0] = x[k++];
                        r1s[imageNum][1] = x[k++];
                        r1s[imageNum][2] = x[k++];
                    }
                    for (int imageNum = 0; imageNum < NUM_IMAGES; imageNum++) {
                        ts[imageNum][0] = x[k++];
                        ts[imageNum][1] = x[k++];
                        ts[imageNum][2] = x[k++];
                    }
                }

                assert(n == k);

                for (int imageNum = 0; imageNum < NUM_IMAGES; imageNum++) {
                    for (int i = 0; i < NUM_POINTS_IN_IMAGE; i++) {
                        double* r0 = &r0s[imageNum][0];
                        double* r1 = &r1s[imageNum][0];
                        double* t = &ts[imageNum][0];
                        double r0r1t[3][3] = {
                            { r0[0], r1[0], t[0] },
                            { r0[1], r1[1], t[1] },
                            { r0[2], r1[2], t[2] }
                        };
                        double H[3][3]; mulMat3Mat3(A, r0r1t, H);
                        double modelPointHom[3] = { Model[i][0], Model[i][1], 1 };

                        double reprojectedImagePoint[3];
                        mulMat3Vec3(H, modelPointHom, reprojectedImagePoint);
                        reprojectedImagePoint[0] /= reprojectedImagePoint[2];
                        reprojectedImagePoint[1] /= reprojectedImagePoint[2];
                        reprojectedImagePoint[2] = 1;

                        double imagePoint[2] = { Image[imageNum][i][0], Image[imageNum][i][1] };

                        double dx = reprojectedImagePoint[0] - imagePoint[0];
                        double dy = reprojectedImagePoint[1] - imagePoint[1];
                        fvec[imageNum * NUM_POINTS_IN_IMAGE + i] = sqrt(dx * dx + dy * dy);
                    }
                }
                return 0;
            }
            # For internal testing to check reprojection error.
            $cc proc callFunc {double[] p0} double {
                double errs[NUM_POINTS_IN_IMAGE * NUM_IMAGES];
                func(NUM_POINTS_IN_IMAGE * NUM_IMAGES,
                     5 + NUM_IMAGES * 9,
                     p0, errs, NULL, NULL);

                double errsum = 0;
                for (int i = 0; i < sizeof(errs)/sizeof(errs[0]); i++) {
                    errsum += errs[i];
                }
                printf("errsum: %f\n", errsum);
                return errsum;
            }
            $cc proc optimize {double[] params} void {
                mp_result result = {0};
                for (int i = 0; i < 9; i++) { printf("params[%d] = %f\n", i, params[i]); }
                callFunc(params);
                mpfit(func, NUM_POINTS_IN_IMAGE * NUM_IMAGES,
                      5 + NUM_IMAGES * 9, params, NULL,
                      NULL, NULL, &result);
                printf("Optimized\n");
                for (int i = 0; i < 9; i++) { printf("params[%d] = %f\n", i, params[i]); }
                callFunc(params);
            }
            $cc compile ;# takes about a half-second

            setModel [concat {*}$modelPoints]
            setImage [concat {*}[concat {*}$imagePointsForDetection]]

            optimize [concat [list $alpha $gamma $u0 $beta $v0] \
                          {*}$r0s {*}$r1s {*}$ts]
        }
        puts "C error: [reprojectionErrorC $alpha $gamma $u0 $beta $v0 $r0s $r1s $ts]"

        # proc ravel {A r0s r1s ts} {
            
        # }
        # proc unravel {p} {
            
        # }
        # proc reprojectionErrorOfParameters {p} {
        #     reprojectionError {*}[unravel $p]
        # }
        

        # set p0 [ravel $A $r0s $r1s $ts]
        # optimize reprojectionErrorOfParameters $p0

    } on error e {
        puts stderr $::errorInfo
    }
}

set loadButtons [list]
foreach path [glob "$::env(HOME)/aux/folk-calibrate-detections/*.tcl"] {
    set name [file rootname [file tail $path]]

    lappend loadButtons [button .load-$name -text $name -command [list apply {{path name} {
        source $path
        loadDetections $name $sideLength $detections
    }} $path $name]]
}
pack {*}$loadButtons -fill both -expand true

vwait forever
