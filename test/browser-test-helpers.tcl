# Shared helpers for test/browser-*.folk. `source` this at the top
# level of a test; the fns are captured into every When below it.
#
# Failures print to the real stderr and exit 1 (an error inside a
# When otherwise just gets logged to /var/tmp/folk-<pid>/ and the test
# hangs).

set browserFixtureUrl "file://[pwd]/test/browser-fixtures"

fn testLog {msg} {
    puts $::realStderr "[file tail $this]: $msg"
}
fn fail {msg} {
    testLog "FAILED: $msg"
    Exit! 1
}
fn check {name script} {
    try {
        uplevel 1 $script
    } on error {e opts} {
        fail "$name: $e\n[errorInfo $e [dict getdef $opts -errorinfo {}]]"
    }
}
fn assertEq {a b} {
    if {$a ne $b} { error "expected \"$b\", got \"$a\"" }
}
fn assertNear {a b eps} {
    if {abs($a - $b) > $eps} { error "expected $b +/- $eps, got $a" }
}

# Pixel color at (x, y) as {r g b} in 0..255.
fn pixel {imageLib im x y} {
    lmap c [$imageLib get $im $x $y] { expr {int(round($c * 255))} }
}
# Is (x, y) within `tol` (per channel) of `rgb`?
fn pixelIs {imageLib im x y rgb {tol 40}} {
    foreach a [pixel $imageLib $im $x $y] b $rgb {
        if {abs($a - $b) > $tol} { return 0 }
    }
    return 1
}
fn assertPixel {imageLib im x y rgb {tol 40}} {
    if {![pixelIs $imageLib $im $x $y $rgb $tol]} {
        error "pixel ($x, $y) is [pixel $imageLib $im $x $y], expected $rgb"
    }
}
# Fraction of an n x n grid of samples in rect {x y w h} matching rgb.
fn fractionMatching {imageLib im rect rgb {n 8} {tol 60}} {
    lassign $rect x y w h
    set hits 0
    for {set i 0} {$i < $n} {incr i} {
        for {set j 0} {$j < $n} {incr j} {
            set px [expr {int($x + ($i + 0.5) * $w / $n)}]
            set py [expr {int($y + ($j + 0.5) * $h / $n)}]
            if {[pixelIs $imageLib $im $px $py $rgb $tol]} { incr hits }
        }
    }
    expr {double($hits) / ($n * $n)}
}

# Each test step Holds `test step $name passed`; the test exits 0
# once every expected step has passed, and fails after `timeout`
# seconds listing the steps that never passed.
fn pass {name} {
    if {[llength [Query! /any/ claims test step $name passed]] == 0} {
        testLog "passed: $name"
    }
    Hold! -key [list test step $name] Claim test step $name passed
}
fn expectSteps {steps timeout} {
    set deadline [expr {[clock milliseconds] / 1000.0 + $timeout}]
    When the clock time is /t/ {
        set missing [lmap s $steps {
            if {[llength [Query! /any/ claims test step $s passed]]} { continue }
            set s
        }]
        if {[llength $missing] == 0} {
            testLog "all [llength $steps] steps passed"
            Exit! 0
        }
        if {[clock milliseconds] / 1000.0 > $deadline} {
            fail "timed out after ${timeout}s; never passed: $missing"
        }
    }
}

# The Chromium-backed tests need uvx (to fetch Playwright). Skip, rather
# than fail, on machines that don't have it.
fn requireBrowserDriver {} {
    if {[file exists "$::env(HOME)/.local/bin/uvx"]} { return }
    foreach dir [split $::env(PATH) :] {
        if {[file executable [file join $dir uvx]]} { return }
    }
    testLog "SKIPPED: no uvx on this machine (needed for the browser driver)"
    Exit! 0
}
