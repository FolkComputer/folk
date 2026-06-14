proc lseq count {
    set ret [list]
    for {set i 0} {$i < $count} {incr i} {
        lappend ret $i
    }
    return $ret
}

# Compute the longest string which is common to all strings given to
# the command, and at the beginning of said strings, i.e. a prefix. If
# only one argument is specified it is treated as a list of the
# strings to look at. If more than one argument is specified these
# arguments are the strings to be looked at. If only one string is
# given, in either form, the string is returned, as it is its own
# longest common prefix.

proc ::textutil::string::longestCommonPrefix {args} {
    return [longestCommonPrefixList $args]
}

proc ::textutil::string::longestCommonPrefixList {list} {
    if {[llength $list] <= 1} {
	return [lindex $list 0]
    }

    set list [lsort $list]
    set min [lindex $list 0]
    set max [lindex $list end]

    # Min and max are the two strings which are most different. If
    # they have a common prefix, it will also be the common prefix for
    # all of them.

    # Fast bailouts for common cases.

    set n [string length $min]
    if {$n == 0} {return ""}
    if {0 == [string compare $min $max]} {return $min}

    set prefix ""
    set i 0
    while {[string index $min $i] == [string index $max $i]} {
	append prefix [string index $min $i]
	if {[incr i] > $n} {break}
    }
    set prefix
}

#######################################################

# @c The specified <a text>block is indented
# @c by <a prefix>ing each line. The first
# @c <a hang> lines ares skipped.
#
# @a text:   The paragraph to indent.
# @a prefix: The string to use as prefix for each line
# @a prefix: of <a text> with.
# @a skip:   The number of lines at the beginning to leave untouched.
#
# @r Basically <a text>, but indented a certain amount.
#
# @i indent
# @n This procedure is not checked by the testsuite.

proc ::textutil::adjust::indent {text prefix {skip 0}} {
    set text [string trimright $text]

    set res [list]
    foreach line [split $text \n] {
	if {[string compare "" [string trim $line]] == 0} {
	    lappend res {}
	} else {
	    set line [string trimright $line]
	    if {$skip <= 0} {
		lappend res $prefix$line
	    } else {
		lappend res $line
	    }
	}
	if {$skip > 0} {incr skip -1}
    }
    return [join $res \n]
}

# Undent the block of text: Compute LCP (restricted to whitespace!)
# and remove that from each line. Note that this preverses the
# shaping of the paragraph (i.e. hanging indent are _not_ flattened)
# We ignore empty lines !!

proc ::textutil::adjust::undent {text} {

    if {$text == {}} {return {}}

    set lines [split $text \n]
    set ne [list]
    foreach l $lines {
	if {[string length [string trim $l]] == 0} continue
	lappend ne $l
    }
    set lcp [::textutil::string::longestCommonPrefixList $ne]

    if {[string length $lcp] == 0} {return $text}

    regexp "^(\[\t \]*)" $lcp -> lcp

    if {[string length $lcp] == 0} {return $text}

    set len [string length $lcp]

    set res [list]
    foreach l $lines {
	if {[string length [string trim $l]] == 0} {
	    lappend res {}
	} else {
	    lappend res [string range $l $len end]
	}
    }
    return [join $res \n]
}
namespace import ::textutil::adjust::*
