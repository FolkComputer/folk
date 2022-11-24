proc tagImageForId {id} {
    # "A BullsEye fiducial consists of a central white dot surrounded
    # by a solid black ring and one or more data rings again
    # surrounded by a solid white ring inside a black ring with three
    # white studs.
    set nextr 0
    proc ring {type {data ""}} {
        upvar nextr nextr
        set cx 0.5; set cy 0.5
        set r $nextr
        set nextr [expr {$nextr + 0.1}]
        subst {
            [expr {$type eq "white" ? 1 : 0}] setgray
            newpath
            $cx $cy $r 0 360 arc
            0.1 setlinewidth
            1 setlinecap
            stroke

            [if {$type eq "data"} {
                
            }]
        }
    }
    subst {
        gsave

        [ring white]    % central white dot
        [ring black]    % solid black ring
        [ring data $id] % data ring
        [ring white]
        [ring black]

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

set fd [file tempfile psfile psfile.ps]; puts $fd $ps; close $fd
exec ps2pdf $psfile [file rootname $psfile].pdf
puts file://[file rootname $psfile].pdf
