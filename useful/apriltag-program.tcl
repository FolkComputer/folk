package require critcl
source "pi/critclUtils.tcl"

critcl::tcl 8.6
if {$tcl_platform(os) eq "Darwin"} {
    critcl::cflags -I/Users/osnr/aux/apriltag -Wall -Werror
    critcl::clibraries /Users/osnr/aux/apriltag/libapriltag.a
} else {
    critcl::cflags -I/home/pi/apriltag -Wall -Werror
    critcl::clibraries /home/pi/apriltag/libapriltag.a
}


critcl::ccode {
    #include <apriltag.h>
    #include <tagStandard52h13.h>

    apriltag_family_t *tf;
}
critcl::cproc init {} void {
    tf = tagStandard52h13_create();
}
critcl::cproc tagForId {int id} string {
    image_u8_t* image = apriltag_to_image(tf, id);
    /* printf("image w=%d, height=%d, stride=%d\n", image->width, image->height, image->stride); */

    char* ret = Tcl_Alloc(10000);
    int i = 0;
    for (int row = 0; row < image->height; row++) {
        for (int col = 0; col < image->width; col++) {
            uint8_t pixel = image->buf[(row * image->stride) + col];
            i += sprintf(&ret[i], "%02x", pixel);
        }
        ret[i++] = '\n';
    }

    image_u8_destroy(image);
    return ret;
}

init

proc programToPs {id text} {
    set PageWidth 612
    set PageHeight 792

    set margin 36

    set tagwidth 150
    set tagheight 150
    set fontsize 12
    set lineheight [expr $fontsize*1.5]

    set image [tagForId $id]

    set linenum 1
    return [subst {
        %!PS
        << /PageSize \[$PageWidth $PageHeight\] >> setpagedevice

        /Monaco findfont
        $fontsize scalefont
        setfont
        newpath
        [join [lmap line [split $text "\n"] {
            set ret "$margin [expr $PageHeight-$margin-$linenum*$lineheight] moveto ($line) show"
            incr linenum
            set ret
        }] "\n"]

        gsave
        [expr $PageWidth-$tagwidth-$margin] [expr $PageHeight-$tagheight-$margin] translate
        $tagwidth $tagheight scale
        10 10 8 \[10 0 0 -10 0 10\]
        {<
$image
        >} image
        grestore

        /Helvetica-Narrow findfont
        10 scalefont
        setfont
        newpath
        [expr $PageWidth-$tagwidth-$margin] [expr $PageHeight-$tagheight-16-$margin] moveto
        ($id ([clock format [clock seconds] -format "%a, %d %b %Y, %r"])) show
    }]
}

puts [programToPs 1 [string trim {
# Tag rectangles
When tag /tag/ has center /c/ size /size/ {
    Claim $tag is a rectangle with x $px y $py \\
        width $size height $size
    Wish $tag is highlighted green
}
}]]
