proc hexcolor color {
    set color 0x$color
    set b [expr {$color & 0xFF}]
    set g [expr {($color >> 8) & 0xFF}]
    set r [expr {($color >> 16) & 0xFF}]

    return [list [/ $r 255.0] [/ $g 255.0] [/ $b 255.0] 1.0]
}

namespace eval Colors {
    variable aliceblue [hexcolor F0F8FF]
    variable antiquewhite [hexcolor FAEBD7]
    variable aqua [hexcolor 00FFFF]
    variable aquamarine [hexcolor 7FFFD4]
    variable azure [hexcolor F0FFFF]
    variable beige [hexcolor F5F5DC]
    variable bisque [hexcolor FFE4C4]
    variable black [hexcolor 000000]
    variable blanchedalmond [hexcolor FFEBCD]
    variable blue [hexcolor 0000FF]
    variable blueviolet [hexcolor 8A2BE2]
    variable brown [hexcolor A52A2A]
    variable burlywood [hexcolor DEB887]
    variable cadetblue [hexcolor 5F9EA0]
    variable chartreuse [hexcolor 7FFF00]
    variable chocolate [hexcolor D2691E]
    variable coral [hexcolor FF7F50]
    variable cornflowerblue [hexcolor 6495ED]
    variable cornsilk [hexcolor FFF8DC]
    variable crimson [hexcolor DC143C]
    variable cyan [hexcolor 00FFFF]
    variable darkblue [hexcolor 00008B]
    variable darkcyan [hexcolor 008B8B]
    variable darkgoldenrod [hexcolor B8860B]
    variable darkgray [hexcolor A9A9A9]
    variable darkgreen [hexcolor 006400]
    variable darkgrey [hexcolor A9A9A9]
    variable darkkhaki [hexcolor BDB76B]
    variable darkmagenta [hexcolor 8B008B]
    variable darkolivegreen [hexcolor 556B2F]
    variable darkorange [hexcolor FF8C00]
    variable darkorchid [hexcolor 9932CC]
    variable darkred [hexcolor 8B0000]
    variable darksalmon [hexcolor E9967A]
    variable darkseagreen [hexcolor 8FBC8F]
    variable darkslateblue [hexcolor 483D8B]
    variable darkslategray [hexcolor 2F4F4F]
    variable darkslategrey [hexcolor 2F4F4F]
    variable darkturquoise [hexcolor 00CED1]
    variable darkviolet [hexcolor 9400D3]
    variable deeppink [hexcolor FF1493]
    variable deepskyblue [hexcolor 00BFFF]
    variable dimgray [hexcolor 696969]
    variable dimgrey [hexcolor 696969]
    variable dodgerblue [hexcolor 1E90FF]
    variable firebrick [hexcolor B22222]
    variable floralwhite [hexcolor FFFAF0]
    variable forestgreen [hexcolor 228B22]
    variable fuchsia [hexcolor FF00FF]
    variable gainsboro [hexcolor DCDCDC]
    variable ghostwhite [hexcolor F8F8FF]
    variable gold [hexcolor FFD700]
    variable goldenrod [hexcolor DAA520]
    variable gray [hexcolor 808080]
    variable green [hexcolor 008000]
    variable greenyellow [hexcolor ADFF2F]
    variable grey [hexcolor 808080]
    variable honeydew [hexcolor F0FFF0]
    variable hotpink [hexcolor FF69B4]
    variable indianred [hexcolor CD5C5C]
    variable indigo [hexcolor 4B0082]
    variable ivory [hexcolor FFFFF0]
    variable khaki [hexcolor F0E68C]
    variable lavender [hexcolor E6E6FA]
    variable lavenderblush [hexcolor FFF0F5]
    variable lawngreen [hexcolor 7CFC00]
    variable lemonchiffon [hexcolor FFFACD]
    variable lightblue [hexcolor ADD8E6]
    variable lightcoral [hexcolor F08080]
    variable lightcyan [hexcolor E0FFFF]
    variable lightgoldenrodyellow [hexcolor FAFAD2]
    variable lightgray [hexcolor D3D3D3]
    variable lightgreen [hexcolor 90EE90]
    variable lightgrey [hexcolor D3D3D3]
    variable lightpink [hexcolor FFB6C1]
    variable lightsalmon [hexcolor FFA07A]
    variable lightseagreen [hexcolor 20B2AA]
    variable lightskyblue [hexcolor 87CEFA]
    variable lightslategray [hexcolor 778899]
    variable lightslategrey [hexcolor 778899]
    variable lightsteelblue [hexcolor B0C4DE]
    variable lightyellow [hexcolor FFFFE0]
    variable lime [hexcolor 00FF00]
    variable limegreen [hexcolor 32CD32]
    variable linen [hexcolor FAF0E6]
    variable magenta [hexcolor FF00FF]
    variable maroon [hexcolor 800000]
    variable mediumaquamarine [hexcolor 66CDAA]
    variable mediumblue [hexcolor 0000CD]
    variable mediumorchid [hexcolor BA55D3]
    variable mediumpurple [hexcolor 9370DB]
    variable mediumseagreen [hexcolor 3CB371]
    variable mediumslateblue [hexcolor 7B68EE]
    variable mediumspringgreen [hexcolor 00FA9A]
    variable mediumturquoise [hexcolor 48D1CC]
    variable mediumvioletred [hexcolor C71585]
    variable midnightblue [hexcolor 191970]
    variable mintcream [hexcolor F5FFFA]
    variable mistyrose [hexcolor FFE4E1]
    variable moccasin [hexcolor FFE4B5]
    variable navajowhite [hexcolor FFDEAD]
    variable navy [hexcolor 000080]
    variable oldlace [hexcolor FDF5E6]
    variable olive [hexcolor 808000]
    variable olivedrab [hexcolor 6B8E23]
    variable orange [hexcolor FFA500]
    variable orangered [hexcolor FF4500]
    variable orchid [hexcolor DA70D6]
    variable palegoldenrod [hexcolor EEE8AA]
    variable palegreen [hexcolor 98FB98]
    variable paleturquoise [hexcolor AFEEEE]
    variable palevioletred [hexcolor DB7093]
    variable papayawhip [hexcolor FFEFD5]
    variable peachpuff [hexcolor FFDAB9]
    variable peru [hexcolor CD853F]
    variable pink [hexcolor FFC0CB]
    variable plum [hexcolor DDA0DD]
    variable powderblue [hexcolor B0E0E6]
    variable purple [hexcolor 800080]
    variable rebeccapurple [hexcolor 663399]
    variable red [hexcolor FF0000]
    variable rosybrown [hexcolor BC8F8F]
    variable royalblue [hexcolor 4169E1]
    variable saddlebrown [hexcolor 8B4513]
    variable salmon [hexcolor FA8072]
    variable sandybrown [hexcolor F4A460]
    variable seagreen [hexcolor 2E8B57]
    variable seashell [hexcolor FFF5EE]
    variable sienna [hexcolor A0522D]
    variable silver [hexcolor C0C0C0]
    variable skyblue [hexcolor 87CEEB]
    variable slateblue [hexcolor 6A5ACD]
    variable slategray [hexcolor 708090]
    variable slategrey [hexcolor 708090]
    variable snow [hexcolor FFFAFA]
    variable springgreen [hexcolor 00FF7F]
    variable steelblue [hexcolor 4682B4]
    variable tan [hexcolor D2B48C]
    variable teal [hexcolor 008080]
    variable thistle [hexcolor D8BFD8]
    variable tomato [hexcolor FF6347]
    variable turquoise [hexcolor 40E0D0]
    variable violet [hexcolor EE82EE]
    variable wheat [hexcolor F5DEB3]
    variable white [hexcolor FFFFFF]
    variable whitesmoke [hexcolor F5F5F5]
    variable yellow [hexcolor FFFF00]
    variable yellowgreen [hexcolor 9ACD32]
}

proc dec2bin5 int {
    set binRep [binary format c $int]
    binary scan $binRep B5 binStr
    return $binStr
}
proc dec2bin6 int {
    set binRep [binary format c $int]
    binary scan $binRep B6 binStr
    return $binStr
}
proc dec2bin8 int {
    set binRep [binary format c $int]
    binary scan $binRep B8 binStr
    return $binStr
}
proc hueToRgb {p q t} {
  if {$t < 0.0} { set t [+ 1.0 $t] }
  if {$t > 1.0} { set t [- 1.0 $t] }
  if {$t < [/ 1 6.0]} { return [expr {$p + ($q - $p) * 6.0 * $t}]}
  if {$t < [/ 1 2.0]} { return $q}
  if {$t < [/ 2 3.0]} { return [expr {$p + ($q - $p) * 6.0 * (2.0 / 3 - $t)}]}
  return $p;
}

proc hslToRgb {h s l} {
    # h: 0 - 360
    # s: 0 - 100
    # l: 0 - 100
    set h [/ $h 360.0]
    set s [/ $s 100.0]
    set l [/ $l 100.0]
    if {$s == 0} {
        set r $l
        set g $l
        set b $l
    } else {
        set q [expr {$l < 0.5 ? $l * (1.0 + $s) : $l + $s - $l * $s}]
        set p [expr {2.0 * $l - $q}]
        set r [hueToRgb $p $q [+ $h [/ 1 3.0]]]
        set g [hueToRgb $p $q $h]
        set b [hueToRgb $p $q [- $h [/ 1 3.0]]]
    }

    return [list $r $g $b]
}

proc ::getColor {color} {
    if {[info exists Colors::$color]} { return [set Colors::$color] }
    
    if {[regexp {hsl\((\d+),(\d+)%,(\d+)%\)} $color -> h s l]} {
        set output [hslToRgb $h $s $l]
        return [list {*}$output 1.0]
    } elseif {[regexp {rgb\((\d+),(\d+),(\d+)\)} $color -> r g b]} {
        return [list [/ $r 255.0] [/ $g 255.0] [/ $b 255.0] 1.0]
    } elseif {[regexp {0x([0-9A-Fa-f]{6})} $color -> hex]} {
        return [hexcolor $hex]
    } elseif {[regexp {0x([0-9A-Fa-f])([0-9A-Fa-f])([0-9A-Fa-f])} $color -> r g b]} {
       return [hexcolor "$r$r$g$g$b$b"]
    } else {
        return $Colors::white
    }
}
