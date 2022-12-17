#!/usr/local/bin/tclsh8.6
puts [pwd]
lappend ::auto_path ../vendor/Img1.4.14-Darwin64
# ## Detect Darwin & load this
package require Tk
package require Img

image create photo icon -file "./images/noun-breathe-clean-air-3046872.png"
image create photo iconDisabled  -file "images/noun-breathe-clean-air-3046872.png"  -format "png -alpha 0.5"
button .b -image icon -command exit

button .b1 -text Hello -underline 0
button .b2 -text World -underline 0
bind . <Key-h> {.b1 flash; .b1 invoke}
bind . <Key-w> {.b2 flash; .b2 invoke}
pack .b .b1 .b2