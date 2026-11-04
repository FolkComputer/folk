# tag-instances.tcl --
#
#     Lets several physical copies of the same AprilTag be on the
#     table at once. Each copy gets its own stable instance id, so
#     each copy runs as its own program.
#
#     The first copy of tag 1234 is simply "1234" (so a single tag
#     behaves exactly as before). Further simultaneous copies are
#     "1234.2", "1234.3", ... An instance id is still numeric, so
#     comparisons like {$tag >= 48600} keep working, and
#     [tagInstances base $this] gives the plain tag id back (which is
#     what program code is stored under).
#
#     All distances are in camera pixels, taken from the detection's
#     center `c` and `size` fields.

namespace eval ::tagInstances {
    # Converts an instance id back to the plain tag id: 1234.2 -> 1234.
    # Anything that is not an instance id is returned unchanged.
    proc base {instance} {
        regsub {^(\d+)\.\d+$} $instance {\1}
    }

    # Builds the instance id for copy number k of tag id.
    proc instanceId {id k} {
        if {$k == 1} { return $id }
        return "$id.$k"
    }

    proc centerDistance {detA detB} {
        lassign [dict get $detA c] ax ay
        lassign [dict get $detB c] bx by
        expr {sqrt(($ax - $bx)*($ax - $bx) + ($ay - $by)*($ay - $by))}
    }
    proc maxSize {detA detB} {
        set a [dict get $detA size]; set b [dict get $detB size]
        expr {$a > $b ? $a : $b}
    }

    # A snapshot is one detector's result for one camera frame
    # (dict with `timestamp` and `dets`, where `dets` are all the
    # detections of a single tag id in that frame). A detector cannot
    # see one physical tag twice in one frame (except when two
    # incremental scan regions overlap, which we collapse here), so
    # the snapshot with the most detections tells us how many copies
    # of the tag are physically present. Fresher snapshots are then
    # only used to update the positions of those copies, never to add
    # copies: that is what keeps a single fast-moving tag from
    # spawning a ghost second copy out of a stale entire-frame
    # detection.
    #
    # Returns one detection per physical copy, each with a
    # `timestamp` field.
    proc collapse {snapshots} {
        set deduped [list]
        foreach snapshot $snapshots {
            set timestamp [dict get $snapshot timestamp]
            set dets [list]
            foreach det [dict get $snapshot dets] {
                set isDuplicate false
                foreach kept $dets {
                    if {[centerDistance $det $kept] < 0.5 * [maxSize $det $kept]} {
                        set isDuplicate true; break
                    }
                }
                if {$isDuplicate} { continue }
                dict set det timestamp $timestamp
                lappend dets $det
            }
            if {[llength $dets] > 0} {
                lappend deduped [dict create timestamp $timestamp dets $dets]
            }
        }
        if {[llength $deduped] == 0} { return [list] }

        # Authoritative snapshot: most copies, then freshest.
        set deduped [lsort -command {apply {{a b} {
            set na [llength [dict get $a dets]]; set nb [llength [dict get $b dets]]
            if {$na != $nb} { return [expr {$nb - $na}] }
            set ta [dict get $a timestamp]; set tb [dict get $b timestamp]
            expr {$tb > $ta ? 1 : ($tb < $ta ? -1 : 0)}
        }}} $deduped]
        set authoritative [lindex $deduped 0]
        set slots [dict get $authoritative dets]
        set authoritativeTimestamp [dict get $authoritative timestamp]

        # Refine slot positions from fresher snapshots, oldest first so
        # the freshest wins. Greedy nearest matching, one detection per
        # slot.
        foreach snapshot [lsort -command {apply {{a b} {
            set ta [dict get $a timestamp]; set tb [dict get $b timestamp]
            expr {$ta > $tb ? 1 : ($ta < $tb ? -1 : 0)}
        }}} [lrange $deduped 1 end]] {
            set timestamp [dict get $snapshot timestamp]
            if {$timestamp <= $authoritativeTimestamp} { continue }

            set pairs [list]
            set i 0
            foreach det [dict get $snapshot dets] {
                set j 0
                foreach slot $slots {
                    lappend pairs [list [centerDistance $det $slot] $i $j]
                    incr j
                }
                incr i
            }
            set usedDets [dict create]; set usedSlots [dict create]
            foreach pair [lsort -real -index 0 $pairs] {
                lassign $pair distance i j
                if {[dict exists $usedDets $i] || [dict exists $usedSlots $j]} { continue }
                dict set usedDets $i 1; dict set usedSlots $j 1
                if {$timestamp > [dict get [lindex $slots $j] timestamp]} {
                    lset slots $j [lindex [dict get $snapshot dets] $i]
                }
            }
        }
        return $slots
    }

    # Gives each physical copy of a tag a copy number k (1, 2, ...)
    # that is stable from frame to frame.
    #
    # prev: dict k -> {c {x y} size S timestamp T}, the copies we
    #   have seen recently on this camera (as returned by the previous
    #   call).
    # dets: the collapsed detections for this frame.
    # now: the current frame timestamp.
    # forgetSeconds: how long an unseen copy keeps its number.
    #
    # Returns {assignments prev'}, where assignments is a flat list of
    # k det pairs.
    proc assign {prev dets now forgetSeconds} {
        # Forget copies that have been gone for a while, so their
        # numbers can be reused.
        set retained [dict create]
        dict for {k entry} $prev {
            if {$now - [dict get $entry timestamp] <= $forgetSeconds} {
                dict set retained $k $entry
            }
        }
        set prev $retained

        set assignments [dict create]
        set unmatched [list]
        for {set i 0} {$i < [llength $dets]} {incr i} { lappend unmatched $i }

        # Pass 1: a copy that is still close to where it was last seen
        # keeps its number. Nearest pairs first.
        set pairs [list]
        dict for {k entry} $prev {
            foreach i $unmatched {
                set det [lindex $dets $i]
                set distance [centerDistance $det $entry]
                if {$distance < 1.5 * [maxSize $det $entry]} {
                    lappend pairs [list $distance $k $i]
                }
            }
        }
        set usedKs [dict create]
        foreach pair [lsort -real -index 0 $pairs] {
            lassign $pair distance k i
            if {[dict exists $usedKs $k] || $i ni $unmatched} { continue }
            dict set usedKs $k 1
            dict set assignments $i $k
            set unmatched [lsearch -all -inline -not -exact $unmatched $i]
        }

        # Pass 2: copies that jumped (or reappeared) take over the
        # numbers that were not claimed by pass 1, preferring the most
        # recently seen number, then the nearest. This is what keeps a
        # lone tag that moves quickly as "1234" rather than turning
        # it into "1234.2".
        set pairs [list]
        dict for {k entry} $prev {
            if {[dict exists $usedKs $k]} { continue }
            foreach i $unmatched {
                lappend pairs [list [dict get $entry timestamp] \
                                   [centerDistance [lindex $dets $i] $entry] $k $i]
            }
        }
        foreach pair [lsort -command {apply {{a b} {
            lassign $a ta da; lassign $b tb db
            if {$ta != $tb} { return [expr {$tb > $ta ? 1 : -1}] }
            expr {$da > $db ? 1 : ($da < $db ? -1 : 0)}
        }}} $pairs] {
            lassign $pair timestamp distance k i
            if {[dict exists $usedKs $k] || $i ni $unmatched} { continue }
            dict set usedKs $k 1
            dict set assignments $i $k
            set unmatched [lsearch -all -inline -not -exact $unmatched $i]
        }

        # Pass 3: genuinely new copies get the lowest free number.
        foreach i $unmatched {
            set k 1
            while {[dict exists $prev $k] || [dict exists $usedKs $k]} { incr k }
            dict set usedKs $k 1
            dict set assignments $i $k
        }

        set result [list]
        for {set i 0} {$i < [llength $dets]} {incr i} {
            set det [lindex $dets $i]
            set k [dict get $assignments $i]
            lappend result $k $det
            dict set prev $k [dict create c [dict get $det c] \
                                  size [dict get $det size] \
                                  timestamp [dict get $det timestamp]]
        }
        return [list $result $prev]
    }

    namespace export base instanceId collapse assign
    namespace ensemble create
}
