# https://wiki.tcl-lang.org/page/Closest+color+name

# color scratchpad
set aliceblue 0xF0F8FF
set antiquewhite 0xFAEBD7
set aqua 0x00FFFF
set aquamarine 0x7FFFD4
set azure 0xF0FFFF
set beige 0xF5F5DC
set bisque 0xFFE4C4
set black 0x000000
set blanchedalmond 0xFFEBCD
set blue 0x0000FF
set blueviolet 0x8A2BE2
set brown 0xA52A2A
set burlywood 0xDEB887
set cadetblue 0x5F9EA0
set chartreuse 0x7FFF00
set chocolate 0xD2691E
set coral 0xFF7F50
set cornflowerblue 0x6495ED
set cornsilk 0xFFF8DC
set crimson 0xDC143C
set cyan 0x00FFFF
set darkblue 0x00008B
set darkcyan 0x008B8B
set darkgoldenrod 0xB8860B
set darkgray 0xA9A9A9
set darkgreen 0x006400
set darkgrey 0xA9A9A9
set darkkhaki 0xBDB76B
set darkmagenta 0x8B008B
set darkolivegreen 0x556B2F
set darkorange 0xFF8C00
set darkorchid 0x9932CC
set darkred 0x8B0000
set darksalmon 0xE9967A
set darkseagreen 0x8FBC8F
set darkslateblue 0x483D8B
set darkslategray 0x2F4F4F
set darkslategrey 0x2F4F4F
set darkturquoise 0x00CED1
set darkviolet 0x9400D3
set deeppink 0xFF1493
set deepskyblue 0x00BFFF
set dimgray 0x696969
set dimgrey 0x696969
set dodgerblue 0x1E90FF
set firebrick 0xB22222
set floralwhite 0xFFFAF0
set forestgreen 0x228B22
set fuchsia 0xFF00FF
set gainsboro 0xDCDCDC
set ghostwhite 0xF8F8FF
set gold 0xFFD700
set goldenrod 0xDAA520
set gray 0x808080
set green 0x008000
set greenyellow 0xADFF2F
set grey 0x808080
set honeydew 0xF0FFF0
set hotpink 0xFF69B4
set indianred 0xCD5C5C
set indigo 0x4B0082
set ivory 0xFFFFF0
set khaki 0xF0E68C
set lavender 0xE6E6FA
set lavenderblush 0xFFF0F5
set lawngreen 0x7CFC00
set lemonchiffon 0xFFFACD
set lightblue 0xADD8E6
set lightcoral 0xF08080
set lightcyan 0xE0FFFF
set lightgoldenrodyellow 0xFAFAD2
set lightgray 0xD3D3D3
set lightgreen 0x90EE90
set lightgrey 0xD3D3D3
set lightpink 0xFFB6C1
set lightsalmon 0xFFA07A
set lightseagreen 0x20B2AA
set lightskyblue 0x87CEFA
set lightslategray 0x778899
set lightslategrey 0x778899
set lightsteelblue 0xB0C4DE
set lightyellow 0xFFFFE0
set lime 0x00FF00
set limegreen 0x32CD32
set linen 0xFAF0E6
set magenta 0xFF00FF
set maroon 0x800000
set mediumaquamarine 0x66CDAA
set mediumblue 0x0000CD
set mediumorchid 0xBA55D3
set mediumpurple 0x9370DB
set mediumseagreen 0x3CB371
set mediumslateblue 0x7B68EE
set mediumspringgreen 0x00FA9A
set mediumturquoise 0x48D1CC
set mediumvioletred 0xC71585
set midnightblue 0x191970
set mintcream 0xF5FFFA
set mistyrose 0xFFE4E1
set moccasin 0xFFE4B5
set navajowhite 0xFFDEAD
set navy 0x000080
set oldlace 0xFDF5E6
set olive 0x808000
set olivedrab 0x6B8E23
set orange 0xFFA500
set orangered 0xFF4500
set orchid 0xDA70D6
set palegoldenrod 0xEEE8AA
set palegreen 0x98FB98
set paleturquoise 0xAFEEEE
set palevioletred 0xDB7093
set papayawhip 0xFFEFD5
set peachpuff 0xFFDAB9
set peru 0xCD853F
set pink 0xFFC0CB
set plum 0xDDA0DD
set powderblue 0xB0E0E6
set purple 0x800080
set rebeccapurple 0x663399
set red 0xFF0000
set rosybrown 0xBC8F8F
set royalblue 0x4169E1
set saddlebrown 0x8B4513
set salmon 0xFA8072
set sandybrown 0xF4A460
set seagreen 0x2E8B57
set seashell 0xFFF5EE
set sienna 0xA0522D
set silver 0xC0C0C0
set skyblue 0x87CEEB
set slateblue 0x6A5ACD
set slategray 0x708090
set slategrey 0x708090
set snow 0xFFFAFA
set springgreen 0x00FF7F
set steelblue 0x4682B4
set tan 0xD2B48C
set teal 0x008080
set thistle 0xD8BFD8
set tomato 0xFF6347
set turquoise 0x40E0D0
set violet 0xEE82EE
set wheat 0xF5DEB3
set white 0xFFFFFF
set whitesmoke 0xF5F5F5
set yellow 0xFFFF00
set yellowgreen 0x9ACD32

proc getColor {color channel} {
    set R 0x[string range $color 2 3]
    set G 0x[string range $color 4 5]
    set B 0x[string range $color 6 7]
    # puts "getColor $R"
    puts "--------------> [expr $R]"
    puts "--------------> [expr $G]"
    puts "--------------> [expr $B]"

    set b [expr {$color & 0xFF}]
    set g [expr {($color >> 8) & 0xFF}]
    set r [expr {($color >> 16) & 0xFF}]


    variable BLUE [color 11111 000000 00000]

    puts "->: $r $g $b"
}

getColor $aliceblue R

# Ideal syntax => Color::color -> 16bit color

## TODO: Namespace Colors
proc getRGBComponent {name RGBchannel 32bit} {
    # name -> one of the named Colors
    # RGBChannel -> one of R, G, or B
    # 32bit -> assumed to be false

    # B
    set result [expr {$name & 0xFF}]
    set result [switch -glob RGBchannel {
        G {expr {($name >> 8) & 0xFF}}
        R {expr {($name >> 16) & 0xFF}}
        default {expr {$name & 0xFF}}
    }]

    # puts $result
    expr {$name & 0xFF}
}

# ---- answer from GPT3: -----
set b [expr {$blue & 0xFF}]
set g [expr {($blue >> 8) & 0xFF}]
set r [expr {($blue >> 16) & 0xFF}]

# 32-bit color
set blue32 [expr {($r << 24) | ($g << 16) | ($b << 8) | 0xFF}]
# create the variable
# set variable blue [list color $b $g $r]
puts [list color $b $g $r]
puts $blue32
# ----- end GPT3 output -----

# set variable blue32 [list color $blue32]
# set variable blueblue [expr {getRGBComponent($blue "B" true)}]
# puts "blue blue $blueblue"

getRGBComponent 0xF0F8FF "R" 1
getRGBComponent 0xF0F8FF "G" 0
getRGBComponent 0xF0F8FF "B" 1

# ----------------------------

# ---- colors from Three.js array ----
# ----

# # Create the array to store the color names and their corresponding RGB values
# array set colors [
#     { aliceblue {240 248 255} }
#     antiquewhite {250 235 215}
#     aqua {0 255 255}
#     aquamarine {127 255 212}
#     azure {240 255 255}
#     beige {245 245 220}
#     bisque {255 228 196}
#     black {0 0 0}
#     # add more color names and RGB values as needed
# ]

# # Example usage
# set colorName "aqua"
# set colorValue [lindex  0]

# parray $colors

# # proc get_color_name {color_value permitted_list} {
# #     set convenient_large_number 10000
# #     set least_distance $convenient_large_number
# #     set set_name unknown

# #     if [regexp #(.*) $color_value -> rgb] {
# #         scan $rgb %2x%2x%2x r0 g0 b0
# #     } else {
# #             # Assume it's a known color name.  In production, one 
# #             #    ought to handle exceptions.
# #         foreach {r0 g0 b0} [get_rgb $color_value] {}
# #     }

# #     foreach name $permitted_list {
# #         lassign [get_rgb $name] r g b
# #             # One can make a case for several other metrics.  This
# #             #    has the advantages of being mathematically robust
# #             #    and maintainable from a software standpoint.
# #         set d [expr abs($r - $r0) + abs($g - $g0) + abs($b - $b0)]
# #         if {!$d} {
# #             return $name
# #         }
# #         if {$d < $least_distance} {
# #             # puts "$name, at ($r, $g, $b), is within $d of ($r0, $g, $b0)."
# #             set least_distance $d
# #             set best_name $name
# #         }
# #     }
# #     return "$best_name +/ $least_distance"
# # }
# #     # Where are these formats documented?
# # proc get_rgb color_name {
# #         # If it's sufficiently important, one might replace the [winfo ...]
# #         #    with a table lookup.  At that point, this script becomes "pure Tcl".
# #     foreach part [winfo rgb . $color_name] {
# #         scan [format %4x $part] %2x%2x first second
# #         lappend list $first
# #     }
# #     return $list
# # }

# # set short_list {red orange yellow green blue violet}

# # set COLORS { snow {ghost white} {white smoke} gainsboro }

# # get_color_name yellow $short_list
# # # get_color_name sienna $short_list     # -> red +/- 222
# # # get_color_name {light coral} $COLORS  # -> light coral
# # # get_color_name #39a051 $COLORS        # -> sea green +/ 38
# # 