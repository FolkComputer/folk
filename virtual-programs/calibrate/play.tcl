source "../../lib/language.tcl"

set fd [open "poses.txt" r]
set calibrationPoses [read $fd]; close $fd

set pose [lindex $calibrationPoses 0]

exec python3 <<[undent [subst -nocommands {
    import matplotlib.pyplot as plt
    import numpy as np

    from mpl_toolkits.mplot3d import Axes3D
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection


    polys = []
    polys.append([[16.9491164719, 17.8960237441, 0.0],
                  [17.89665059755603, 27.22995253575736, 0.0],
                  [17.89665059755603, 27.22995253575736, 2.552],  # note the permutation of
                  [16.9491164719, 17.8960237441, 2.552],          # these two points
    ])


    fig = plt.figure()
    ax = fig.add_subplot(projection='3d')

    # Draw camera frame points.


    # Draw projector frame points.


    # Draw reprojected frame points.
    
    
    ax.add_collection3d(Poly3DCollection(polys))

    ax.set_ylim3d(0,5)
    ax.set_xlim3d(0,5)
    ax.set_zlim3d(0,5)
    plt.show()
}]]


exit 0

package require Tk

lappend auto_path "../../vendor"
package require math::linearalgebra
rename ::scale scaleTk
foreach p {add norm sub scale matmul
    getelem transpose determineSVD shape mkIdentity show
    solvePGauss crossproduct getcol setcol unitLengthVector det
} {
    namespace import ::math::linearalgebra::$p
}

set poseNum 0
foreach pose $calibrationPoses {
    lappend loadButtons [button .load-$poseNum -text pose[incr poseNum] -command [list apply {{poseNum pose} {
        toplevel .pose$poseNum
        set canv .pose$poseNum.canv
        canvas $canv -width 1280 -height 720 -background white

        dict for {id tag} [dict get $pose model] {
            set p [lmap v [dict get $tag p] {
                set v [matmul [dict get $pose H_modelToDisplay] [list {*}$v 1]]
                list [expr {[lindex $v 0] / [lindex $v 2]}] \
                    [expr {[lindex $v 1] / [lindex $v 2]}]
            }]
            $canv create line {*}[join $p] {*}[lindex $p 0]
        }
        dict for {id tag} [dict get $pose tags] {
            set p [dict get $tag p]
            $canv create line {*}[join $p] {*}[lindex $p 0]
        }

        pack .pose$poseNum.canv
    }} $poseNum $pose]]
}
pack {*}$loadButtons -fill both -expand true
vwait forever
