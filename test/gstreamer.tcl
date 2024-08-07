loadVirtualPrograms [list "virtual-programs/gstreamer.folk" "virtual-programs/images.folk"]
Step

# namespace eval Pipeline $::makePipeline
# set pl [Pipeline::create "videotestsrc"]
# Pipeline::play $pl
# set img [Pipeline::frame $pl]
# Pipeline::freeImage $img
# Pipeline::destroy $pl

When the gstreamer pipeline "videotestsrc" frame is /frame/ at /ts/ {
  Wish the web server handles route "/gst-image/$" with handler [list apply {{im} {
   set filename "/tmp/web-image-frame.png"
   image saveAsPng $im $filename
   set fsize [file size $filename]
   set fd [open $filename r]
   fconfigure $fd -encoding binary -translation binary
   set body [read $fd $fsize]
   close $fd
   dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: image/png\nContent-Length: $fsize\n\n" body $body
  }} $frame]
}

forever { Step }
