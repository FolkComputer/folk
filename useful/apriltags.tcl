cd ~/aux/apriltag-imgs ;# https://github.com/AprilRobotics/apriltag-imgs
cd tagStandard52h13

puts "[llength [glob *.png]] tags"

set sizeInches 1
proc drawTag {id sizeInches} {
    set tagPng tag52_13_[format %-05s $id].png
    puts [exec identify $tagPng]

    set sizePx [expr $sizeInches * 144]
    set outPng [exec mktemp -t test_tag_[set sizeInches]in].png
    exec convert $tagPng -filter point -resize [set sizePx]x[set sizePx] -bordercolor white -border 20 \
        -pointsize 24 "label:$sizeInches in" -gravity Center \
        -append $outPng

    return $outPng
}

set tagSizes [list 1 3 5]
set drawnPngs [list]
foreach tagSize $tagSizes {
    set drawnPng [drawTag 0 $tagSize]
    lappend drawnPngs $drawnPng
}

set outPdf [exec mktemp -t test_tags].pdf
exec magick {*}$drawnPngs -gravity center -density 144 -extent 1224x1584\! $outPdf
exec open $outPdf
