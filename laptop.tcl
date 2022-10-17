package require Tk

namespace eval Display {
    variable WIDTH 800
    variable HEIGHT 600

    variable black black
    variable blue  blue
    variable green green
    variable red   red

    canvas .display -background black -width $Display::WIDTH -height $Display::HEIGHT
    pack .display
    wm title . $::nodename
    wm geometry . [set Display::WIDTH]x[expr {$Display::HEIGHT + 40}]-0+0 ;# align to top-right of screen

    proc init {} {}

    proc fillRect {fb x0 y0 x1 y1 color} {
        uplevel [list Wish display runs [list .display create rectangle $x0 $y0 $x1 $y1 -fill $color]]
    }

    proc stroke {points width color} {
        uplevel [list Wish display runs [list .display create line {*}[join $points] -fill $color]]
    }

    proc text {fb x y fontSize text} {
        uplevel [list Wish display runs [list .display create text $x $y -text $text -font "Helvetica $fontSize" -fill white]]
    }

    proc commit {} {
        .display delete all

        set displayList [list]
        foreach match [Statements::findMatches {/someone/ wishes display runs /command/}] {
            lappend displayList [dict get $match command]
        }

        proc lcomp {a b} {expr {[lindex $a 2] == "text"}}
        eval [join [lsort -command lcomp $displayList] "\n"]
    }
}

if {[info exists ::env(FOLK_SHARE_NODE)]} {
    set ::shareNode $::env(FOLK_SHARE_NODE)
} else {
    set ::shareNode "folk0.local"
}

# copy to Pi
if {[catch {
    # TODO: forward entry point
    # TODO: handle rsync strict host key failure
    catch {exec rsync --timeout=1 -e "ssh -o StrictHostKeyChecking=no" -a . pi@$::shareNode:~/folk-rsync}
    exec ssh -o StrictHostKeyChecking=no pi@$::shareNode -- make -C ~/folk-rsync restart >@stdout &
} err]} {
    puts "error running on Pi: $err"
    unset ::shareNode
}

package require Thread
if {[info exists ::shareNode]} {
    set ::sharerThread [thread::create [format {
        thread::wait
        set sock [socket {%s} 4273]
        puts $sock {
        }
        close $sock
    } $::shareNode]]
}
proc StepFromGUI {} {
    Step

    if {![info exists ::shareNode]} { return }

    # share root statement set to Pi
    set assertedClauses [clauseset create]
    dict for {_ stmt} $Statements::statements {
        if {[statement setsOfParents $stmt] == {0 {}}} {
            clauseset add assertedClauses [statement clause $stmt]
        }
    }
    thread::send -async $::sharerThread [format {
        if {[catch {
            set shareNode {%s}
            set nodename {%s}
            set assertedClauses {%s}

            set sock [socket $shareNode 4273]
            puts $sock [list set ::nextSenderNode $nodename]
            puts $sock [list set ::nextAssertedClauses $assertedClauses]
            puts $sock {
                if [catch {
                    set prevAssertedClauses [dict get $::assertedClausesFrom $::nextSenderNode]
                }] { set prevAssertedClauses [clauseset create] }

                set retractClauses [clauseset difference $prevAssertedClauses $::nextAssertedClauses]
                foreach clause [clauseset clauses $retractClauses] { Retract {*}$clause }
                set assertClauses [clauseset difference $::nextAssertedClauses $prevAssertedClauses]
                foreach clause [clauseset clauses $assertClauses] { Assert {*}$clause }

                dict set ::assertedClausesFrom $::nextSenderNode $::nextAssertedClauses
                unset ::nextSenderNode
                unset ::nextAssertedClauses
            }
            # if {$nodename == "[info hostname]-1"} {
                # puts $sock {Step}
            # }
            close $sock

        } err]} {
            puts stderr "share error: $err"
        }
    } $::shareNode $::nodename $assertedClauses]
}

set ::nextProgramNum 0
set defaultCode {Wish $this is highlighted blue}
proc newProgram "{programCode {$defaultCode}} {programFilename 0}" {
    set programNum [incr ::nextProgramNum]
    if {$programFilename != 0} {
        set program [string map {. ^} $::nodename:$programFilename]
    } else {
        set program [string map {. ^} $::nodename]:program$programNum
    }

    toplevel .$program
    wm title .$program $program
    wm geometry .$program 350x250+[expr {20 + $programNum*20}]+[expr {20 + $programNum*20}]

    text .$program.t
    .$program.t insert 1.0 $programCode
    pack .$program.t -expand true -fill both
    focus .$program.t

    proc handleSave {program programFilename} {
        # https://wiki.tcl-lang.org/page/Text+processing+tips
        set code [.$program.t get 1.0 end-1c]

        # display save
        catch {destroy .$program.saved}
        if {$programFilename != 0} {
            set fp [open $programFilename w]
            puts -nonewline $fp $code
            close $fp
            label .$program.saved -text "Saved to $programFilename!"
        } else {
            label .$program.saved -text "Saved!"
        }
        place .$program.saved -x 40 -y 100
        after 500 "catch {destroy .$program.saved}"

        Retract "laptop.tcl" claims $program has program code /something/
        Assert "laptop.tcl" claims $program has program code $code

        StepFromGUI
    }
    bind .$program <Control-Key-s> [list handleSave $program $programFilename]
    proc handlePrint {program} {
        set code [.$program.t get 1.0 end-1c]
        set jobid [exec uuidgen]
        Assert "laptop.tcl" wishes to print $code with job id $jobid
        label .$program.printing -text "Printing!"
        place .$program.printing -x 40 -y 100
        StepFromGUI

        after 500 [subst {
            catch {destroy .$program.printing}
            Retract "laptop.tcl" wishes to print /code/ with job id $jobid
        }]
    }
    bind .$program <Command-Key-p> [list handlePrint $program]
    proc handleConfigure {program x y w h} {
        Retract "laptop.tcl" claims $program is a rectangle with x /something/ y /something/ width /something/ height /something/
        Assert "laptop.tcl" claims $program is a rectangle with x $x y $y width $w height $h

        StepFromGUI
    }
    bind .$program <Configure> [subst -nocommands {
        # HACK: we get some weird stray Configure event
        # where w and h are 1, so ignore that
        if {"%W" eq [winfo toplevel %W] && %w > 1} {
            handleConfigure $program %x %y %w %h
        }
    }]
    bind .$program <Destroy> [subst -nocommands {
        if {"%W" eq [winfo toplevel %W]} {
            puts "destroy $program"
            # temporarily unbind this program
            # (if it's a file, it'll still survive on disk when you restart the system)
            Retract "laptop.tcl" claims $program has program code /something/
            Retract "laptop.tcl" claims $program is a rectangle with x /something/ y /something/ width /something/ height /something/
            StepFromGUI
        }
    }]

    handleSave $program $programFilename
}
button .btn -text "New Program" -command newProgram
pack .btn
bind . <Control-Key-n> newProgram

foreach programFilename [glob virtual-programs/*.folk] {
    set fp [open $programFilename r]
    newProgram [read $fp] $programFilename
    close $fp
}

Display::init

vwait forever
