cd ~/aux/apriltag-imgs ;# https://github.com/AprilRobotics/apriltag-imgs
cd tagStandard52h13

puts "[llength [glob *.png]] tags"

set sizeInches 1
proc drawTag {id sizeInches} {
    set tagPng tag52_13_[format %-05s $id].png
    puts [exec identify $tagPng]

    set sizePx [expr $sizeInches * 144]
    set outPng [exec mktemp -t test_tag].png
    exec convert $tagPng -filter point -resize [set sizePx]x[set sizePx] $outPng

    return $outPng
}

set tagSizes [list 1 5 10]
foreach tagSize $tagSizes {
    lappend tagPngs [drawTag 0 $tagSize]
    # TODO: draw text under the tag png
}

foreach tagPng $tagPngs {
    exec open $tagPng
}

# TODO: composite with the other tag pngs?

#        -gravity center -density 144 -extent 1224x1584\! $outPdf
#    exec open $outPdf

# TODO: overlay multiple fiducials of diff sizes on one page
# TODO: draw the fiducial size under the fiducial
