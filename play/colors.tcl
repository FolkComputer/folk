# https://wiki.tcl-lang.org/page/Closest+color+name

namespace eval Color {}

namespace eval Color {
# color scratchpad
variable aliceblue 0xF0F8FF
variable antiquewhite 0xFAEBD7
variable aqua 0x00FFFF
variable aquamarine 0x7FFFD4
variable azure 0xF0FFFF
variable beige 0xF5F5DC
variable bisque 0xFFE4C4
variable black 0x000000
variable blanchedalmond 0xFFEBCD
variable blue 0x0000FF
variable blueviolet 0x8A2BE2
variable brown 0xA52A2A
variable burlywood 0xDEB887
variable cadetblue 0x5F9EA0
variable chartreuse 0x7FFF00
variable chocolate 0xD2691E
variable coral 0xFF7F50
variable cornflowerblue 0x6495ED
variable cornsilk 0xFFF8DC
variable crimson 0xDC143C
variable cyan 0x00FFFF
variable darkblue 0x00008B
variable darkcyan 0x008B8B
variable darkgoldenrod 0xB8860B
variable darkgray 0xA9A9A9
variable darkgreen 0x006400
variable darkgrey 0xA9A9A9
variable darkkhaki 0xBDB76B
variable darkmagenta 0x8B008B
variable darkolivegreen 0x556B2F
variable darkorange 0xFF8C00
variable darkorchid 0x9932CC
variable darkred 0x8B0000
variable darksalmon 0xE9967A
variable darkseagreen 0x8FBC8F
variable darkslateblue 0x483D8B
variable darkslategray 0x2F4F4F
variable darkslategrey 0x2F4F4F
variable darkturquoise 0x00CED1
variable darkviolet 0x9400D3
variable deeppink 0xFF1493
variable deepskyblue 0x00BFFF
variable dimgray 0x696969
variable dimgrey 0x696969
variable dodgerblue 0x1E90FF
variable firebrick 0xB22222
variable floralwhite 0xFFFAF0
variable forestgreen 0x228B22
variable fuchsia 0xFF00FF
variable gainsboro 0xDCDCDC
variable ghostwhite 0xF8F8FF
variable gold 0xFFD700
variable goldenrod 0xDAA520
variable gray 0x808080
variable green 0x008000
variable greenyellow 0xADFF2F
variable grey 0x808080
variable honeydew 0xF0FFF0
variable hotpink 0xFF69B4
variable indianred 0xCD5C5C
variable indigo 0x4B0082
variable ivory 0xFFFFF0
variable khaki 0xF0E68C
variable lavender 0xE6E6FA
variable lavenderblush 0xFFF0F5
variable lawngreen 0x7CFC00
variable lemonchiffon 0xFFFACD
variable lightblue 0xADD8E6
variable lightcoral 0xF08080
variable lightcyan 0xE0FFFF
variable lightgoldenrodyellow 0xFAFAD2
variable lightgray 0xD3D3D3
variable lightgreen 0x90EE90
variable lightgrey 0xD3D3D3
variable lightpink 0xFFB6C1
variable lightsalmon 0xFFA07A
variable lightseagreen 0x20B2AA
variable lightskyblue 0x87CEFA
variable lightslategray 0x778899
variable lightslategrey 0x778899
variable lightsteelblue 0xB0C4DE
variable lightyellow 0xFFFFE0
variable lime 0x00FF00
variable limegreen 0x32CD32
variable linen 0xFAF0E6
variable magenta 0xFF00FF
variable maroon 0x800000
variable mediumaquamarine 0x66CDAA
variable mediumblue 0x0000CD
variable mediumorchid 0xBA55D3
variable mediumpurple 0x9370DB
variable mediumseagreen 0x3CB371
variable mediumslateblue 0x7B68EE
variable mediumspringgreen 0x00FA9A
variable mediumturquoise 0x48D1CC
variable mediumvioletred 0xC71585
variable midnightblue 0x191970
variable mintcream 0xF5FFFA
variable mistyrose 0xFFE4E1
variable moccasin 0xFFE4B5
variable navajowhite 0xFFDEAD
variable navy 0x000080
variable oldlace 0xFDF5E6
variable olive 0x808000
variable olivedrab 0x6B8E23
variable orange 0xFFA500
variable orangered 0xFF4500
variable orchid 0xDA70D6
variable palegoldenrod 0xEEE8AA
variable palegreen 0x98FB98
variable paleturquoise 0xAFEEEE
variable palevioletred 0xDB7093
variable papayawhip 0xFFEFD5
variable peachpuff 0xFFDAB9
variable peru 0xCD853F
variable pink 0xFFC0CB
variable plum 0xDDA0DD
variable powderblue 0xB0E0E6
variable purple 0x800080
variable rebeccapurple 0x663399
variable red 0xFF0000
variable rosybrown 0xBC8F8F
variable royalblue 0x4169E1
variable saddlebrown 0x8B4513
variable salmon 0xFA8072
variable sandybrown 0xF4A460
variable seagreen 0x2E8B57
variable seashell 0xFFF5EE
variable sienna 0xA0522D
variable silver 0xC0C0C0
variable skyblue 0x87CEEB
variable slateblue 0x6A5ACD
variable slategray 0x708090
variable slategrey 0x708090
variable snow 0xFFFAFA
variable springgreen 0x00FF7F
variable steelblue 0x4682B4
variable tan 0xD2B48C
variable teal 0x008080
variable thistle 0xD8BFD8
variable tomato 0xFF6347
variable turquoise 0x40E0D0
variable violet 0xEE82EE
variable wheat 0xF5DEB3
variable white 0xFFFFFF
variable whitesmoke 0xF5F5F5
variable yellow 0xFFFF00
variable yellowgreen 0x9ACD32
}



# https://wiki.tcl-lang.org/page/Binary+representation+of+numbers
proc dec2bin int {
    set binRep [binary format c $int]
    binary scan $binRep B* binStr
    return $binStr
}


proc RGB2fbColor {b g r} { expr 0b[join [list $r $g $b] ""] }

# TODO: if {$Display::DEPTH == 16} format colors as:
#                        B (5)  G (6)  R (5)
# variable green  [color 00000 111111 00000]
# & if {Display::DEPTH == 32}:
#                        B (8)      G (8)    R (8)
# variable green  [color 00000000 11111111 00000000]
proc hex2fbColor color {
    set b [expr {$color & 0xFF}]
    set g [expr {($color >> 8) & 0xFF}]
    set r [expr {($color >> 16) & 0xFF}]

    set fbColor "\[[dec2bin $b]\] \[[dec2bin $g]\] \[[dec2bin $r]\]"
    return $fbColor
}

# getColor $aliceblue R
puts "green: [hex2fbColor $Color::green]"
puts "full green: [hex2fbColor 0x00FF00]"
puts "red:   [hex2fbColor $Color::red]"
puts "blue:  [hex2fbColor $Color::blue]"

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
# set b [expr {$blue & 0xFF}]
# set g [expr {($blue >> 8) & 0xFF}]
# set r [expr {($blue >> 16) & 0xFF}]

# # 32-bit color
# set blue32 [expr {($r << 24) | ($g << 16) | ($b << 8) | 0xFF}]
# # create the variable
# # set variable blue [list color $b $g $r]
# puts [list color $b $g $r]
# puts $blue32
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