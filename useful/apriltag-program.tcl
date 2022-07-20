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

    set tagwidth 150
    set tagheight 150

    set image [tagForId $id]

    return [subst {
        %!PS
        << /PageSize \[$PageWidth $PageHeight\] >> setpagedevice
        
        /Monaco findfont
        12 scalefont
        setfont
        newpath
        72 [expr $PageHeight-72] moveto
        ($text) show

        [expr $PageWidth-$tagwidth-72] [expr $PageHeight-$tagheight-72] translate
        $tagwidth $tagheight scale
        10 10 8 \[10 0 0 -10 0 10\]
        {<
$image
        >} image
    }]
}

puts [programToPs 1 [string trim {
    # Tag rectangles
    When tag /tag/ has center /c/ size /size/ {
	Claim $tag is a rectangle with x $px y $py width $size height $size
	Wish $tag is highlighted green
    }
}]]

# cd ~/aux/apriltag-imgs ;# https://github.com/AprilRobotics/apriltag-imgs
# cd tagStandard52h13

# puts "[llength [glob *.png]] tags"

# set sizeInches 1
# proc drawTag {id sizeInches} {
#     set tagPng tag52_13_[format %05s $id].png
#     puts [exec identify $tagPng]

#     set sizePx [expr $sizeInches * 172]
#     set outPng [exec mktemp -t test_tag_[set sizeInches]in].png
#     exec convert $tagPng -filter point -resize [set sizePx]x[set sizePx] -bordercolor white -border 20 \
#         -pointsize 24 "label: $id ($sizeInches in)" -gravity Center \
#         -append $outPng

#     return $outPng
# }

# set tagId 3

# set tagSizes [list 3]
# set drawnPngs [list]
# foreach tagSize $tagSizes {
#     set drawnPng [drawTag $tagId $tagSize]
#     lappend drawnPngs $drawnPng
# }

# set outPdf [exec mktemp -t test_tags].pdf
# exec magick {*}$drawnPngs -gravity center -density 144 -extent 1224x1584\! $outPdf
# exec open $outPdf
