loadVirtualPrograms [list "virtual-programs/web/webrtc.folk" "virtual-programs/web/web-keyboards.folk" "virtual-programs/keyboard.folk" "virtual-programs/gstreamer.folk" "virtual-programs/images.folk" "virtual-programs/web/new-program-web-editor.folk"]
Step

# Assert <unknown> wishes the-moon receives webrtc video earth

When the-moon has webrtc video earth frame /image/ at /ts/ {
  Wish the web server handles route "/rtc-image/$" with handler [list apply {{im} {
   set filename "/tmp/web-image-frame.png"
   image saveAsPng $im $filename
   set fsize [file size $filename]
   set fd [open $filename r]
   fconfigure $fd -encoding binary -translation binary
   set body [read $fd $fsize]
   close $fd
   dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: image/png\nContent-Length: $fsize\n\n" body $body
  }} $image]
}

forever { Step }
