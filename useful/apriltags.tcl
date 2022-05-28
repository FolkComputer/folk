cd ~/aux/apriltag-imgs ;# https://github.com/AprilRobotics/apriltag-imgs
cd tagStandard52h13

puts "[llength [glob *.png]] tags"

set tagPng tag52_13_00000.png
puts [exec identify $tagPng]

set sizeInches 1
set sizePx [expr $sizeInches * 144]
set outPdf [exec mktemp -t test_tag].pdf
exec convert $tagPng -filter point -resize [set sizePx]x[set sizePx] -gravity center -density 144 -extent 1224x1584\! $outPdf
exec open $outPdf
