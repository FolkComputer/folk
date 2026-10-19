# JSON encoding and decoding.
#
# Ported from jimtcl, which supplied both as built-ins until Folk moved to
# zicl. `json::encode` is a near-verbatim port of jimtcl's `jsonencode.tcl`;
# `json::decode` is a fresh implementation of the same surface, since the
# original was a C wrapper around jsmn.
#
# The value mapping, in both directions:
#
#     object      <-> dict
#     array       <-> list
#     string      <-> string
#     number      <-> its literal text
#     true/false  <-> true/false
#     null         -> the -null value, "null" unless overridden
#     Infinity     -> Inf (and -Infinity -> -Inf), matching what encode emits

# Everything lives in one scope and is exported at the bottom through
# [letrec select]: `subencode` recurses, the parser is mutually recursive, and
# a plain [fn] captures its scope before its siblings are bound.
set jsonScope [dict create]

# `schema` describes the shape of `value`, since Tcl cannot tell a list from a
# string from a number on its own:
#
#     str             string (the default)
#     num             numeric, or null
#     bool            boolean
#     obj name sub    object; `name` matches a dict key and `sub` is its
#                     subschema, with `*` as a catch-all
#     list sub        array, `sub` describing every element
#     mixed sub ...   array, one subschema per element
fn jsonScope::encode {value {schema str}} {
    return [subencode [lindex $schema 0] $value [lrange $schema 1 end]]
}

fn jsonScope::subencode {type value {schema {}}} {
    switch -exact -- $type {
        str - "" {
            # Strictly we should be converting \x00 through \x1F to unicode
            # escapes, and anything outside the BMP to a UTF-16 surrogate pair.
            return \"[string map [list \\ \\\\ \" \\" \f \\f \n \\n / \\/ \b \\b \r \\r \t \\t] $value]\"
        }
        num {
            if {$value in {Inf -Inf}} {
                append value inity
            }
            return $value
        }
        bool {
            # jimtcl leant on Tcl's truthiness here, which zicl deliberately
            # does not have: booleans are not numbers.
            if {$value eq "true" || $value eq "1"} { return true }
            if {$value eq "false" || $value eq "0"} { return false }
            error "json::encode: not a boolean: \"$value\""
        }
        obj {
            set result "\{"
            set sep " "
            foreach k [lsort [dict keys $value]] {
                if {[dict exists $schema $k]} {
                    set subtype [dict get $schema $k]
                } elseif {[dict exists $schema *]} {
                    set subtype [dict get $schema *]
                } else {
                    set subtype str
                }
                append result $sep\"$k\":
                append result [subencode [lindex $subtype 0] \
                                   [dict get $value $k] [lrange $subtype 1 end]]
                set sep ", "
            }
            append result " \}"
            return $result
        }
        list {
            set result "\["
            set sep " "
            foreach l $value {
                append result $sep
                append result [subencode [lindex $schema 0] $l [lrange $schema 1 end]]
                set sep ", "
            }
            append result " \]"
            return $result
        }
        mixed {
            set result "\["
            set sep " "
            foreach l $value subtype $schema {
                append result $sep
                append result [subencode [lindex $subtype 0] $l [lrange $subtype 1 end]]
                set sep ", "
            }
            append result " \]"
            return $result
        }
        default {
            error "json::encode: bad type \"$type\""
        }
    }
}

# One pass to cut the text into tokens, then a walk over the token list. The
# `]` leading the punctuation class is a literal, per the usual character-class
# rule.
set jsonTokenPattern {"(?:[^"\\]|\\.)*"|-?(?:[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?|Infinity)|true|false|null|[][{}:,]}

fn jsonScope::unescape {token} {
    set body [string range $token 1 end-1]
    if {[string first "\\" $body] < 0} { return $body }

    set out ""
    set n [string length $body]
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $body $i]
        if {$c ne "\\"} { append out $c; continue }

        incr i
        switch -exact -- [string index $body $i] {
            n { append out \n }
            t { append out \t }
            r { append out \r }
            b { append out \b }
            f { append out \f }
            u {
                # Python's json.dumps defaults to ensure_ascii, so every
                # non-ASCII character arrives in this form.
                set hex [string range $body [expr {$i + 1}] [expr {$i + 4}]]
                append out [format %c [expr "0x$hex"]]
                incr i 4
            }
            default { append out [string index $body $i] }
        }
    }
    return $out
}

# Each of these returns {value indexJustPastIt}.
fn jsonScope::parseValue {tokens i null} {
    set token [lindex $tokens $i]
    if {$token eq "\{"} { return [parseObject $tokens [expr {$i + 1}] $null] }
    if {$token eq "\["} { return [parseArray $tokens [expr {$i + 1}] $null] }

    incr i
    if {[string index $token 0] eq "\""} { return [list [unescape $token] $i] }
    if {$token eq "null"} { return [list $null $i] }
    if {$token eq "Infinity"} { return [list Inf $i] }
    if {$token eq "-Infinity"} { return [list -Inf $i] }
    return [list $token $i]
}

fn jsonScope::parseObject {tokens i null} {
    set result [dict create]
    if {[lindex $tokens $i] eq "\}"} { return [list $result [expr {$i + 1}]] }

    while true {
        set key [unescape [lindex $tokens $i]]
        incr i 2
        lassign [parseValue $tokens $i $null] value i
        dict set result $key $value

        set sep [lindex $tokens $i]
        incr i
        if {$sep eq "\}"} { return [list $result $i] }
        if {$sep ne ","} { error "json::decode: expected \",\" or \"\}\", got \"$sep\"" }
    }
}

fn jsonScope::parseArray {tokens i null} {
    set result [list]
    if {[lindex $tokens $i] eq "\]"} { return [list $result [expr {$i + 1}]] }

    while true {
        lassign [parseValue $tokens $i $null] value i
        lappend result $value

        set sep [lindex $tokens $i]
        incr i
        if {$sep eq "\]"} { return [list $result $i] }
        if {$sep ne ","} { error "json::decode: expected \",\" or \"\]\", got \"$sep\"" }
    }
}

# jimtcl also took -index and -schema. Nothing in Folk used either, so they
# are absent rather than silently accepted and ignored.
fn jsonScope::decode {args} {
    set null "null"
    set i 0
    while {$i < [llength $args] - 1} {
        set opt [lindex $args $i]
        if {$opt eq "--"} { incr i; break }
        if {$opt ne "-null"} { error "json::decode: unsupported option \"$opt\"" }
        set null [lindex $args [expr {$i + 1}]]
        incr i 2
    }
    if {$i != [llength $args] - 1} { error "json::decode: wrong # args" }

    set text [lindex $args end]
    if {$text eq ""} { error "empty JSON string" }

    set tokens [regexp -all -inline $jsonTokenPattern $text]
    if {[llength $tokens] == 0} { error "json::decode: no JSON value in \"$text\"" }

    lassign [parseValue $tokens 0 $null] value next
    if {$next != [llength $tokens]} { error "json::decode: trailing garbage" }
    return $value
}

set json::encode [letrec select $jsonScope encode]
set json::subencode [letrec select $jsonScope subencode]
set json::decode [letrec select $jsonScope decode]
