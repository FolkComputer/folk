fn audioVolumeDefault {} {
    return 0.5
}

fn audioVolumeClamp {value} {
    if {![string is double -strict $value]} {
        return [audioVolumeDefault]
    }
    if {$value < 0.0} {
        return 0.0
    }
    if {$value > 1.0} {
        return 1.0
    }
    return [expr {double($value)}]
}

fn audioVolumeNormalizeValue {value} {
    set value [string trim $value]
    if {[string match {*%} $value]} {
        set percent [string trimright $value %]
        if {[string is double -strict $percent]} {
            return [audioVolumeClamp [expr {double($percent) / 100.0}]]
        }
        return [audioVolumeDefault]
    }

    if {![string is double -strict $value]} {
        return [audioVolumeDefault]
    }

    if {$value > 1.0} {
        return [audioVolumeClamp [expr {double($value) / 100.0}]]
    }
    return [audioVolumeClamp $value]
}

fn audioVolumePercent {volume} {
    return [expr {int(round([audioVolumeClamp $volume] * 100.0))}]
}

fn audioVolumeDialVolumeFromVector {dx dy} {
    set minAngle [expr {-3.141592653589793 * 0.75}]
    set maxAngle [expr { 3.141592653589793 * 0.75}]
    set angle [expr {atan2($dx, -$dy)}]

    if {$angle < $minAngle} {
        return 0.0
    }
    if {$angle > $maxAngle} {
        return 1.0
    }
    return [audioVolumeClamp [expr {($angle - $minAngle) / ($maxAngle - $minAngle)}]]
}

fn audioVolumeDialPointerFromVolume {volume radius} {
    set minAngle [expr {-3.141592653589793 * 0.75}]
    set maxAngle [expr { 3.141592653589793 * 0.75}]
    set angle [expr {$minAngle + [audioVolumeClamp $volume] * ($maxAngle - $minAngle)}]
    return [list [expr {sin($angle) * $radius}] [expr {-cos($angle) * $radius}]]
}
