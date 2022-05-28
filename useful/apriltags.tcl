cd ~/aux/apriltag-imgs ;# https://github.com/AprilRobotics/apriltag-imgs
cd tagStandard52h13

puts "[llength [glob *.png]] tags"

set tagPng tag52_13_00000.png
puts [exec identify $tagPng]

set outPdf [exec mktemp -t test_tag].pdf
exec convert $tagPng -scale 5000% -gravity center -extent 612x792\! $outPdf
exec open $outPdf
