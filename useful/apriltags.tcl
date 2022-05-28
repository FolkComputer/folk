cd ~/aux/apriltag-imgs ;# https://github.com/AprilRobotics/apriltag-imgs
cd tagStandard52h13

puts "[llength [glob *.png]] tags"

set tempPng [exec mktemp -t test_tag].png
exec convert tag52_13_00000.png -scale 500% $tempPng
exec open $tempPng
