set KeyCodes [dict create]

proc keydef {code val {shiftVal ""}} {
  upvar KeyCodes KeyCodes
  if {$shiftVal == ""} {
    set shiftVal $val
  }
  dict set KeyCodes $code [list $val $shiftVal]
}

proc keyFromCode {code {shift false}} {
  upvar KeyCodes KeyCodes
  if {[dict exists $KeyCodes $code]} {
    set vals [dict get $KeyCodes $code]
    return [lindex $vals [expr {$shift ? 1 : 0}]]
  }
  puts "WARNING: unknown key code \"$code\""
  return "?"
}

# Keycodes from https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h
keydef 0		{RESERVED}
keydef 1		{ESC}
keydef 2		{1} {!}
keydef 3		{2} {@}
keydef 4		{3} {#}
keydef 5		{4} {$}
keydef 6		{5} {%}
keydef 7		{6} {^}
keydef 8		{7} {&}
keydef 9		{8} {*}
keydef 10		{9} {(}
keydef 11		{0} {)}
keydef 12		{-} {_}
keydef 13		{=} {+}
keydef 14		{BACKSPACE}
keydef 15		{TAB}
keydef 16		{q} {Q}
keydef 17		{w} {W}
keydef 18		{e} {E}
keydef 19		{r} {R}
keydef 20		{t} {T}
keydef 21		{y} {Y}
keydef 22		{u} {U}
keydef 23		{i} {I}
keydef 24		{o} {O}
keydef 25		{p} {P}
keydef 26		{[} "\{"
keydef 27		{]} "\}"
keydef 28		{ENTER}
keydef 29		{LEFTCTRL}
keydef 30		{a} {A}
keydef 31		{s} {S}
keydef 32		{d} {D}
keydef 33		{f} {F}
keydef 34		{g} {G}
keydef 35		{h} {H}
keydef 36		{j} {J}
keydef 37		{k} {K}
keydef 38		{l} {L}
keydef 39		{;} {:}
keydef 40		{'} "\""
keydef 41		{`} {~}
keydef 42		{LEFTSHIFT}
keydef 43		"\\" {|}
keydef 44		{z} {Z}
keydef 45		{x} {X}
keydef 46		{c} {C}
keydef 47		{v} {V}
keydef 48		{b} {B}
keydef 49		{n} {N}
keydef 50		{m} {M}
keydef 51		{,} {<}
keydef 52		{.} {>}
keydef 53		{/} {?}
keydef 54		{RIGHTSHIFT}
keydef 55		{KPASTERISK}
keydef 56		{LEFTALT}
keydef 57		{ } ;# SPACE
keydef 58		{CAPSLOCK}
keydef 59		{F1}
keydef 60		{F2}
keydef 61		{F3}
keydef 62		{F4}
keydef 63		{F5}
keydef 64		{F6}
keydef 65		{F7}
keydef 66		{F8}
keydef 67		{F9}
keydef 68		{F10}
keydef 69		{NUMLOCK}
keydef 70		{SCROLLLOCK}
keydef 71		{KP7}
keydef 72		{KP8}
keydef 73		{KP9}
keydef 74		{KPMINUS}
keydef 75		{KP4}
keydef 76		{KP5}
keydef 77		{KP6}
keydef 78		{KPPLUS}
keydef 79		{KP1}
keydef 80		{KP2}
keydef 81		{KP3}
keydef 82		{KP0}
keydef 83		{KPDOT}

keydef 85		{ZENKAKUHANKAKU}
keydef 86		{102ND}
keydef 87		{F11}
keydef 88		{F12}
keydef 89		{RO}
keydef 90		{KATAKANA}
keydef 91		{HIRAGANA}
keydef 92		{HENKAN}
keydef 93		{KATAKANAHIRAGANA}
keydef 94		{MUHENKAN}
keydef 95		{KPJPCOMMA}
keydef 96		{KPENTER}
keydef 97		{RIGHTCTRL}
keydef 98		{KPSLASH}
keydef 99		{SYSRQ}
keydef 100		{RIGHTALT}
keydef 101		{LINEFEED}
keydef 102		{HOME}
keydef 103		{UP}
keydef 104		{PAGEUP}
keydef 105		{LEFT}
keydef 106		{RIGHT}
keydef 107		{END}
keydef 108		{DOWN}
keydef 109		{PAGEDOWN}
keydef 110		{INSERT}
keydef 111		{DELETE}
keydef 112		{MACRO}
keydef 113		{MUTE}
keydef 114		{VOLUMEDOWN}
keydef 115		{VOLUMEUP}
keydef 116		{POWER}
keydef 117		{KPEQUAL}
keydef 118		{KPPLUSMINUS}
keydef 119		{PAUSE}
keydef 120		{SCALE}

