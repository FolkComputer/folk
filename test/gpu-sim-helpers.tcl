# Helpers for tests that run the real GPU stack without a screen, on a
# software Vulkan driver, rendering to draw.folk's "offscreen" display.

# Prefer lavapipe (Mesa's software Vulkan) when it's installed and no
# driver was chosen explicitly, so tests render the same everywhere.
if {![info exists ::env(VK_ICD_FILENAMES)] &&
    [file exists /usr/share/vulkan/icd.d/lvp_icd.json]} {
    set ::env(VK_ICD_FILENAMES) /usr/share/vulkan/icd.d/lvp_icd.json
}

# Sources the GPU stack in dependency order. The caller must already
# have wished `$::thisNode uses display "offscreen" with ...` (draw.folk
# reads that once, shortly after it starts).
fn sourceGpuStack {} {
    foreach f {
        builtin-programs/collect.folk
        builtin-programs/image/image-lib.folk
        builtin-programs/image/png-lib.folk
        builtin-programs/gpu/enumerate.folk
        builtin-programs/gpu/gpu.folk
        builtin-programs/gpu/vma.folk
        builtin-programs/gpu/textures.folk
        builtin-programs/gpu/pipelines.folk
        builtin-programs/gpu/gpu-fns.folk
        builtin-programs/gpu/canvases.folk
        builtin-programs/gpu/draw.folk
        builtin-programs/draw/color-map.folk
        builtin-programs/draw/fill.folk
        builtin-programs/draw/image.folk
    } {
        When [list source $f]
    }
}

# A flat "table" display: 1 m = 1000 px, no lens, quads already in
# display space (identity quad changer). Mirrors what
# tags-to-quads.folk needs to composite page canvases onto a display.
fn fakeDisplay {disp} {
    Claim display $disp has intrinsics {}
    Claim the pose library is [library create simPose {} {
        proc project {intrinsics width height v} {
            list [expr {[lindex $v 0] * 1000}] [expr {[lindex $v 1] * 1000}]
        }
    }]
    fn identityQuadChange {q space} { return $q }
    Claim the quad changer is [fn identityQuadChange]
    When { source builtin-programs/quad-lib.folk }

    # Composite each page's canvas onto the display from its quad
    # (same as the rule at the end of tags-to-quads.folk, which needs
    # the AprilTag library and so isn't sourced here).
    When the quad library is /quadLib/ &\
         the pose library is /poseLib/ &\
         the quad changer is /quadChange/ &\
         display $disp has width /displayWidth/ height /displayHeight/ &\
         display $disp has intrinsics /displayIntrinsics/ &\
         /tag/ has canvas /writableTextureId/ with /...wiOptions/ {
        if {$tag eq $disp} { return }
        fn quadChange
        set displayToClip [list \
            [list [expr {2.0/$displayWidth}] 0 -1] \
            [list 0 [expr {2.0/$displayHeight}] -1] \
            [list 0 0 1]]
        When -atomically $tag has quad /quad/ {
            lassign [lmap v [$quadLib vertices [quadChange $quad "display $disp"]] {
                $poseLib project $displayIntrinsics $displayWidth $displayHeight $v
            }] a b c d
            Wish the GPU draws pipeline "image" with arguments \
                [list [list $displayWidth $displayHeight] \
                     $displayToClip \
                     [dict get $wiOptions texture] $a $b $c $d] \
                layer [dict getdef $wiOptions layer 0]
        }
    }
}

# Where tests save snapshot PNGs: $FOLK_SNAPSHOT_DIR if set, else a
# folder under the system temp dir (cleaned up by whoever set it).
fn snapshotDir {} {
    if {[info exists ::env(FOLK_SNAPSHOT_DIR)] && $::env(FOLK_SNAPSHOT_DIR) ne ""} {
        file mkdir $::env(FOLK_SNAPSHOT_DIR)
        return $::env(FOLK_SNAPSHOT_DIR)
    }
    set dir "/tmp/folk-snapshots"
    file mkdir $dir
    return $dir
}
