package require Tk

# This demonstration script creates a text widget that illustrates the
# various display styles that may be set for tags. 
# Modified from the demo widget example provided in the Tcl release

text .t -yscrollcommand ".scroll set" -setgrid true \
        -width 40 -height 10 -wrap word
scrollbar .scroll -command ".t yview"
pack .scroll -side right -fill y
pack .t -expand yes -fill both

# Now insert text that has the property of the tags
.t insert end "Here are a few text styles.\n"
