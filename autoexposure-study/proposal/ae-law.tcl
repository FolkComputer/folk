# Pure-Tcl autoexposure control law (no Folk dependencies) so it can be
# unit-tested with a plain jimsh. This exact text is embedded in the
# proposed builtin-programs/camera/autoexposure.folk.

# aeNextExposure --
#
#   cur:   currently commanded exposure in microseconds
#   stats: list of per-tag dicts {white W black B satFrac S} where white is
#          the mean of the brightest quarter of samples inside the tag,
#          black the mean of the darkest quarter, and satFrac the fraction
#          of that brightest quarter that is clipped (>= 250)
#   lo/hi: allowed exposure range in microseconds
#
# Returns the exposure to command next. Returning exactly $cur means
# "leave the camera alone".
proc aeNextExposure {cur stats lo hi} {
    # Aim the tags' white cells at ~200/255: bright enough for a solid
    # black/white split, with headroom so noise and gradients across a
    # tag do not clip at 255 (once whites clip we can no longer tell
    # how overexposed we are).
    set target 200.0
    # No actuation while within +-deadband of the target: sensor noise
    # and JPEG wobble must not turn into exposure churn.
    set deadband 12.0
    # Proportional gain in the log domain (1.0 = jump straight to the
    # estimated ideal; smaller = smoother, more robust to the 1-3 frame
    # actuation latency of V4L2 cameras).
    set gain 0.6
    # Never move more than this factor per step.
    set maxRatio 1.5
    # If more than this fraction of the "white" samples is clipped, the
    # white measurement is meaningless; back off by a fixed factor.
    set clipFrac 0.25
    set clipStep 0.7

    if {[llength $stats] == 0} { return $cur }

    # Median across tags: one tag under projector spill, a specular
    # highlight or a shadow should not drag everyone else.
    set whites [lsort -real [lmap s $stats {dict get $s white}]]
    set sats [lsort -real [lmap s $stats {dict get $s satFrac}]]
    set mid [expr {[llength $whites] / 2}]
    set white [lindex $whites $mid]
    set sat [lindex $sats $mid]

    if {$sat > $clipFrac} {
        set ratio $clipStep
    } else {
        set err [expr {$target - $white}]
        if {abs($err) <= $deadband} { return $cur }
        if {$white < 1.0} { set white 1.0 }
        # 8-bit pixel values go roughly as exposure^(1/2.2) (sRGB-ish
        # camera tone curve), so the exposure ratio that fixes a pixel
        # ratio is pow(pixelRatio, 2.2).
        set ratio [expr {pow($target / $white, 2.2 * $gain)}]
        if {$ratio > $maxRatio} { set ratio $maxRatio }
        if {$ratio < 1.0 / $maxRatio} { set ratio [expr {1.0 / $maxRatio}] }
    }

    # V4L2 exposure_time_absolute has 100us granularity: keep our own
    # state on that grid so it matches what the camera actually does,
    # and always move by at least one step in the commanded direction
    # (otherwise small ratios at short exposures stall forever).
    set next [expr {int($cur * $ratio) / 100 * 100}]
    if {$next == $cur} {
        set next [expr {$ratio > 1.0 ? $cur + 100 : $cur - 100}]
    }
    if {$next < $lo} { set next $lo }
    if {$next > $hi} { set next $hi }
    return $next
}

# aeSweepExposure --
#
#   Used when no tag has been decodable for a while: the exposure is
#   probably so far off that nothing can be measured. Walk the range
#   geometrically (x1.6 per step) in direction dir (+1 up, -1 down),
#   bouncing at the ends. Returns {next newDir}.
proc aeSweepExposure {cur dir lo hi} {
    set step 1.6
    if {$dir > 0} {
        set next [expr {int($cur * $step) / 100 * 100}]
        if {$next >= $hi} { set next $hi; set dir -1 }
    } else {
        set next [expr {int($cur / $step) / 100 * 100}]
        if {$next <= $lo} { set next $lo; set dir 1 }
    }
    return [list $next $dir]
}
