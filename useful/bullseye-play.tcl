# generate BullsEye fiducial PostScript
# emit to terminal

proc tagImageForId {id} {
    subst {
        gsave

        1 setgray
        newpath
        0 0 moveto
        1 0 lineto
        1 1 lineto
        0 1 lineto
        0 0 lineto
        closepath fill

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
