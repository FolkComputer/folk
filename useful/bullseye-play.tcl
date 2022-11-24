proc tagImageForId {id} {
    # "A BullsEye fiducial consists of a central white dot surrounded
    # by a solid black ring and one or more data rings again
    # surrounded by a solid white ring inside a black ring with three
    # white studs.
    set nextr 0
    proc ring {type {bits {}}} {
        if {$type eq "white"} { set bits {1} } \
        elseif {$type eq "black"} { set bits {0} }

        upvar nextr nextr
        set cx 0.5; set cy 0.5
        set degrees [expr {360.0 / [llength $bits]}]
        set r $nextr
        set nextr [expr {$nextr + 0.1}]

        set i 0
        join [lmap bit $bits {
            set angle [expr {$i*$degrees}]
            incr i
            subst {
                newpath
                $cx $cy $r $angle [expr {$angle+$degrees}] arc
                0.1 setlinewidth
                [expr {[llength $bits] == 1 ? 1 : 0}] setlinecap
                $bit setgray
                stroke
            }
        }] "\n"
    }
    subst {
        gsave

        [ring white]    % central white dot
        [ring black]    % solid black ring
        [ring data [split [format "%07b" $id] ""]] % data ring
        [ring white]    % again surrounded by a solid white ring
        [ring data [list 1 {*}[lrepeat 10 0] 1 0 1 {*}[lrepeat 10 0]]] % inside a black ring with white studs

        grestore
    }
}

proc programToPs {id text} {
    set PageWidth 612; set PageHeight 792
    set margin 36

    set tagwidth 150; set tagheight 150
    set fontsize 12; set lineheight [expr $fontsize*1.5]

    set image [tagImageForId $id]

    set linenum 1
    subst {
        %!PS
        << /PageSize \[$PageWidth $PageHeight\] >> setpagedevice

        /Courier findfont
        $fontsize scalefont
        setfont
        newpath
        [join [lmap line [split $text "\n"] {
            set line [string map {"\\" "\\\\"} $line]
            set ret "$margin [expr $PageHeight-$margin-$linenum*$lineheight] moveto ($line) show"
            incr linenum
            set ret
        }] "\n"]

        gsave
        [expr $PageWidth-$tagwidth-$margin] [expr $PageHeight-$tagheight-$margin] translate
        $tagwidth $tagheight scale
        $image
        grestore

        /Helvetica-Narrow findfont
        10 scalefont
        setfont
        newpath
        [expr $PageWidth-$tagwidth-$margin] [expr $PageHeight-$tagheight-16-$margin] moveto
        ($id ([clock format [clock seconds] -format "%a, %d %b %Y, %r"])) show
    }
}

set ps [programToPs 66 "hello"]
# puts $ps

set fd [file tempfile psfile psfile.ps]; puts $fd $ps; close $fd
exec ps2pdf $psfile [file rootname $psfile].pdf
puts file://[file rootname $psfile].pdf
