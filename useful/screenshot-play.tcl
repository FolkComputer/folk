 lappend ::auto_path ../vendor/Img1.4.14-Darwin64
 package require Tk
 package require Img

 proc CaptureWindow {win {baseImg ""} {px 0} {py 0}} {
   # create the base image of win (the root of capturing process)
   if {$baseImg eq ""} {
     set baseImg [image create photo -format window -data $win]
   }
   # paste images of win's children on the base image
   foreach child [winfo children $win] {
     if {![winfo ismapped $child]} continue
     set childImg [image create photo -format window -data $child]
     regexp {\+(\d*)\+(\d*)} [winfo geometry $child] -> x y
     $baseImg copy $childImg -to [incr x $px] [incr y $py]
     image delete $childImg
     CaptureWindow $child $baseImg $x $y
   }
   return $baseImg
 }

 proc windowToFile { win } {
   set image [CaptureWindow $win]
   set types {{"Image Files" {.gif}}}
   set filename [tk_getSaveFile -filetypes $types \
                                  -initialfile capture.gif \
                                -defaultextension .gif]
   if {[llength $filename]} {
       $image write -format gif $filename
       puts "Written to file: $filename"
   } else {
       puts "Write cancelled"
   }
   image delete $image
 }

 proc demo { } {

    package require Tk
    wm withdraw .
    set top .t
    toplevel $top
    wm title $top "Demo"
    frame $top.f
    pack  $top.f -fill both -expand 1
    label $top.f.hello -text "Press x to capture window"
    pack  $top.f.hello -s top -e 0 -f none -padx 10 -pady 10

    checkbutton $top.f.b1 -text "CheckButton 1"
    checkbutton $top.f.b2 -text "CheckButton 2"
    radiobutton $top.f.r1 -text "RadioButton 1" -variable num -value 1
    radiobutton $top.f.r2 -text "RadioButton 2" -variable num -value 2

    pack $top.f.b1 $top.f.b2 $top.f.r1 $top.f.r2 \
        -side top -expand 0 -fill none 

    update
    bind $top <Key-x> [list windowToFile $top]
 }

 demo