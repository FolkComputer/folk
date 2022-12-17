if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded zlibtcl 1.2.13 [list load [file join $dir libtcl9zlibtcl1.2.13.dylib]]
} else {
    package ifneeded zlibtcl 1.2.13 [list load [file join $dir libzlibtcl1.2.13.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded pngtcl 1.6.38 [list load [file join $dir libtcl9pngtcl1.6.38.dylib]]
} else {
    package ifneeded pngtcl 1.6.38 [list load [file join $dir libpngtcl1.6.38.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded tifftcl 4.4.0 [list load [file join $dir libtcl9tifftcl4.4.0.dylib]]
} else {
    package ifneeded tifftcl 4.4.0 [list load [file join $dir libtifftcl4.4.0.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded jpegtcl 9.5.0 [list load [file join $dir libtcl9jpegtcl9.5.0.dylib]]
} else {
    package ifneeded jpegtcl 9.5.0 [list load [file join $dir libjpegtcl9.5.0.dylib]]
}
# -*- tcl -*- Tcl package index file
# --- --- --- Handcrafted, final generation by configure.

if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::base 1.4.14 [list load [file join $dir libtcl9tkimg1.4.14.dylib]]
} else {
    package ifneeded img::base 1.4.14 [list load [file join $dir libtkimg1.4.14.dylib]]
}
# Compatibility hack. When asking for the old name of the package
# then load all format handlers and base libraries provided by tkImg.
# Actually we ask only for the format handlers, the required base
# packages will be loaded automatically through the usual package
# mechanism.

# When reading images without specifying it's format (option -format),
# the available formats are tried in reversed order as listed here.
# Therefore file formats with some "magic" identifier, which can be
# recognized safely, should be added at the end of this list.

package ifneeded Img 1.4.14 {
    package require img::window
    package require img::tga
    package require img::ico
    package require img::pcx
    package require img::sgi
    package require img::sun
    package require img::xbm
    package require img::xpm
    package require img::ps
    package require img::jpeg
    package require img::png
    package require img::tiff
    package require img::bmp
    package require img::ppm
    package require img::gif
    package require img::pixmap
    package provide Img 1.4.14
}

if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::bmp 1.4.14 [list load [file join $dir libtcl9tkimgbmp1.4.14.dylib]]
} else {
    package ifneeded img::bmp 1.4.14 [list load [file join $dir libtkimgbmp1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::gif 1.4.14 [list load [file join $dir libtcl9tkimggif1.4.14.dylib]]
} else {
    package ifneeded img::gif 1.4.14 [list load [file join $dir libtkimggif1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::ico 1.4.14 [list load [file join $dir libtcl9tkimgico1.4.14.dylib]]
} else {
    package ifneeded img::ico 1.4.14 [list load [file join $dir libtkimgico1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::jpeg 1.4.14 [list load [file join $dir libtcl9tkimgjpeg1.4.14.dylib]]
} else {
    package ifneeded img::jpeg 1.4.14 [list load [file join $dir libtkimgjpeg1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::pcx 1.4.14 [list load [file join $dir libtcl9tkimgpcx1.4.14.dylib]]
} else {
    package ifneeded img::pcx 1.4.14 [list load [file join $dir libtkimgpcx1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::pixmap 1.4.14 [list load [file join $dir libtcl9tkimgpixmap1.4.14.dylib]]
} else {
    package ifneeded img::pixmap 1.4.14 [list load [file join $dir libtkimgpixmap1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::png 1.4.14 [list load [file join $dir libtcl9tkimgpng1.4.14.dylib]]
} else {
    package ifneeded img::png 1.4.14 [list load [file join $dir libtkimgpng1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::ppm 1.4.14 [list load [file join $dir libtcl9tkimgppm1.4.14.dylib]]
} else {
    package ifneeded img::ppm 1.4.14 [list load [file join $dir libtkimgppm1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::ps 1.4.14 [list load [file join $dir libtcl9tkimgps1.4.14.dylib]]
} else {
    package ifneeded img::ps 1.4.14 [list load [file join $dir libtkimgps1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::sgi 1.4.14 [list load [file join $dir libtcl9tkimgsgi1.4.14.dylib]]
} else {
    package ifneeded img::sgi 1.4.14 [list load [file join $dir libtkimgsgi1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::sun 1.4.14 [list load [file join $dir libtcl9tkimgsun1.4.14.dylib]]
} else {
    package ifneeded img::sun 1.4.14 [list load [file join $dir libtkimgsun1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::tga 1.4.14 [list load [file join $dir libtcl9tkimgtga1.4.14.dylib]]
} else {
    package ifneeded img::tga 1.4.14 [list load [file join $dir libtkimgtga1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::tiff 1.4.14 [list load [file join $dir libtcl9tkimgtiff1.4.14.dylib]]
} else {
    package ifneeded img::tiff 1.4.14 [list load [file join $dir libtkimgtiff1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::window 1.4.14 [list load [file join $dir libtcl9tkimgwindow1.4.14.dylib]]
} else {
    package ifneeded img::window 1.4.14 [list load [file join $dir libtkimgwindow1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::xbm 1.4.14 [list load [file join $dir libtcl9tkimgxbm1.4.14.dylib]]
} else {
    package ifneeded img::xbm 1.4.14 [list load [file join $dir libtkimgxbm1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::xpm 1.4.14 [list load [file join $dir libtcl9tkimgxpm1.4.14.dylib]]
} else {
    package ifneeded img::xpm 1.4.14 [list load [file join $dir libtkimgxpm1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::dted 1.4.14 [list load [file join $dir libtcl9tkimgdted1.4.14.dylib]]
} else {
    package ifneeded img::dted 1.4.14 [list load [file join $dir libtkimgdted1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::raw 1.4.14 [list load [file join $dir libtcl9tkimgraw1.4.14.dylib]]
} else {
    package ifneeded img::raw 1.4.14 [list load [file join $dir libtkimgraw1.4.14.dylib]]
}
if {[package vsatisfies [package provide Tcl] 9.0-]} {
    package ifneeded img::flir 1.4.14 [list load [file join $dir libtcl9tkimgflir1.4.14.dylib]]
} else {
    package ifneeded img::flir 1.4.14 [list load [file join $dir libtkimgflir1.4.14.dylib]]
}
