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

    proc fillRect {x0 y0 x1 y1 color} {
        uplevel [list Wish display runs [list .display create rectangle $x0 $y0 $x1 $y1 -fill $color]]
    }

    proc stroke {points width color} {
        uplevel [list Wish display runs [list .display create line {*}[join $points] -fill $color]]
    }

    proc text {fb x y fontSize text {radians 0}} {
        uplevel [list Wish display runs [list .display create text $x $y -text $text -font "Helvetica $fontSize" -fill white]]
    }

    variable displayTime
    proc commit {} {
        .display delete all

        set displayList [list]
        foreach match [Statements::findMatches {/someone/ wishes display runs /command/}] {
            lappend displayList [dict get $match command]
        }

        proc lcomp {a b} {expr {[lindex $a 2] == "text"}}
        variable displayTime
        set displayTime [time {
            eval [join [lsort -command lcomp $displayList] "\n"]
        }]
    }
}

proc StepFromGUI {} { Step }

proc randomRangeString {length {chars "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"}} {
    set range [expr {[string length $chars]-1}]

    set txt ""
    for {set i 0} {$i < $length} {incr i} {
       set pos [expr {int(rand()*$range)}]
       append txt [string range $chars $pos $pos]
    }
    return $txt
}
set ::nextProgramNum 0
proc newProgram {{programCode {Wish $this is outlined blue}} {program ""}} {
    set programNum [incr ::nextProgramNum]
    set program [string map {. ^} $program]
    if {$program eq ""} {
        set program [string tolower [string map {. ^} $::nodename]]:program-[randomRangeString 10]
    }

    toplevel .$program
    wm title .$program $program
    # Format: width x height + x + y
    # Formula: (n * windowDimension) + gutter
    wm geometry .$program 350x250+[expr $programNum * 25]+[expr {$programNum * 35}]

    text .$program.t
    .$program.t insert 1.0 $programCode
    pack .$program.t -expand true -fill both
    focus .$program.t

    proc handleSave {program} {
        # https://wiki.tcl-lang.org/page/Text+processing+tips
        set code [.$program.t get 1.0 end-1c]

        catch {destroy .$program.saved}

        label .$program.saved -text "Saved!"
        place .$program.saved -x 40 -y 100
        after 500 "catch {destroy .$program.saved}"

        Retract "laptop.tcl" claims $program has program code /something/
        Assert "laptop.tcl" claims $program has program code $code

        StepFromGUI
    }
    bind .$program <Control-Key-s> [list handleSave $program]
    bind .$program <Command-Key-s> [list handleSave $program]
    proc handlePrint {program} {
        set code [.$program.t get 1.0 end-1c]
        # hack to remove filename from printed program
        set code [regsub {\s*Wish \$this has filename [^\n]+\s*} $code ""]
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
        # Save position to disk so it reloads at next startup:
        dict set ::programPositions $program "wm geometry .$program [set w]x[set h]+[set x]+[set y]"
        set fp [open "virtual-programs/program-positions.tcl" w]
        puts -nonewline $fp [join [dict values $::programPositions] "\n"]
        close $fp

        Evaluator::runInSerializedEnvironment {
            set vertices [list [list $x $y] \
                              [list [expr {$x+$w}] $y] \
                              [list [expr {$x+$w}] [expr {$y+$h}]] \
                              [list $x [expr {$y+$h}]]]
            set edges [list [list 0 1] [list 1 2] [list 2 3] [list 3 0]]
            Commit $program region {
                Say "laptop.tcl" claims $program has region [list $vertices $edges]
            }
        } [dict create program $program x $x y $y w $w h $h]

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
            Evaluator::runInSerializedEnvironment {
                Commit $program region {}
            } {}
            StepFromGUI
        }
    }]
    bind .$program <Control-Key-n> newProgram
    bind .$program <Command-Key-n> newProgram

    handleSave $program
}
button .btn -text "New Program" -command newProgram
pack .btn
bind . <Control-Key-n> newProgram
bind . <Command-Key-n> newProgram

set ::chs [list]
proc handleKeyPress {k} {
    lappend ::chs $k
    Retract keyboard claims the keyboard character log is /something/
    Assert keyboard claims the keyboard character log is $::chs
    Step
}
bind . <KeyPress> {handleKeyPress %K}

# also see how it's done in pi.tcl
foreach programFilename [list {*}[glob virtual-programs/*.folk] \
                             {*}[glob virtual-programs/*/*.folk] \
                             {*}[glob -nocomplain "user-programs/[info hostname]/*.folk"]] {
    # Skip archived programs.
    if {[string first "/archive/" $programFilename] != -1} {
        continue
    }

    set fp [open $programFilename r]
    newProgram [read $fp] $programFilename
    close $fp
}
catch {
    set fp [open "virtual-programs/program-positions.tcl" r]
    eval [read $fp]
    close $fp
}

Assert when /program/ has program code /code/ {
    if {!$::isLaptop} { return }
    When /someone/ wishes $program has filename /filename/ {
        wm title .$program $filename
        
        set fp [open "virtual-programs/$filename" w]
        puts -nonewline $fp $code
        close $fp
        puts "Saved $program to $filename"

        catch {.$program.saved configure -text "Saved to $filename!"}
    }
}
Assert when /program/ has error /err/ with info /info/ {
    catch {
        label .$program.err -text "Error: $err\n$info" -background red
        place .$program.err -x 40 -y 100
    }

    On unmatch {
        catch {destroy .$program.err}
    }
}

source "hosts.tcl"
if {[info exists ::shareNode]} {
    # copy to Pi
    if {[catch {
        # TODO: forward entry point
        # TODO: handle rsync strict host key failure
        exec -ignorestderr make sync FOLK_SHARE_NODE=$::shareNode
        exec -ignorestderr ssh folk@$::shareNode -- sudo systemctl restart folk >@stdout &
    } err]} {
        puts "error syncing: $err"
        puts "Proceeding without sharing to table."

    } else {
        source "lib/peer.tcl"
        peer $::shareNode

        Assert "laptop.tcl" is providing root statements
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" is providing root statements]
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" claims /program/ has program code /code/]
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" claims /program/ has region /region/]
        Assert "laptop.tcl" wishes $::nodename shares statements like \
            [list "laptop.tcl" wishes to print /code/ with job id /jobid/]
    }
}

Display::init
StepFromGUI

vwait forever
