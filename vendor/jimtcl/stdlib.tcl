# Implements script-based standard commands for Jim Tcl

if {![exists -command ref]} {
	# No support for references, so create a poor-man's reference just good enough for lambda
	proc ref {args} {{count 0}} {
		format %08x [incr count]
	}
}

# Creates an anonymous procedure
proc lambda {arglist args} {
	tailcall proc [ref {} function lambda.finalizer] $arglist {*}$args
}

proc lambda.finalizer {name val} {
	rename $name {}
}

# Like alias, but creates and returns an anonyous procedure
proc curry {args} {
	alias [ref {} function lambda.finalizer] {*}$args
}

# Returns the given argument.
# Useful with 'local' as follows:
#   proc a {} {...}
#   local function a
#
#   set x [lambda ...]
#   local function $x
#
proc function {value} {
	return $value
}

# Returns a live stack trace as a list of proc filename line ...
# with 3 entries for each stack frame (proc),
# (deepest level first)
proc stacktrace {{skip 0}} {
	set trace {}
	# Need to skip info frame 0 and this (stacktrace) level
	incr skip 2
	loop level $skip [info level]+1 {
		set frame [info frame -$level]
		lappend trace [lindex [dict get $frame cmd] 0] [dict get $frame file] [dict get $frame line]
	}
	return $trace
}
proc stacktrace {{skip 0}} {
	set trace {}
	# skip the internal frames
	incr skip 1
	set last 0
	loop level $skip [info frame]+1 {
		set frame [info frame -$level]
		set file [dict get $frame file]
		set line [dict get $frame line]
		set lev [dict get $frame level]
		if {$lev != $last && $lev > $skip} {
			set proc [lindex [dict get $frame cmd] 0]
			lappend trace $proc $file $line
		}
		set last $lev
	}
	return $trace
}

# Returns a human-readable version of a stack trace
proc stackdump {stacktrace} {
	set lines {}
	foreach {l f p} [lreverse $stacktrace] {
		set line {}
		if {$p ne ""} {
			append line "in procedure '$p' "
			if {$f ne ""} {
				append line "called "
			}
		}
		if {$f ne ""} {
			append line "at file \"$f\", line $l"
		}
		if {$line ne ""} {
			lappend lines $line
		}
	}
	join $lines \n
}

# Add the given script to $jim::defer, to be evaluated when the current
# procedure exits
proc defer {script} {
	upvar jim::defer v
	lappend v $script
}

# Sort of replacement for $::errorInfo
# Usage: errorInfo error ?stacktrace?
proc errorInfo {msg {stacktrace ""}} {
	if {$stacktrace eq ""} {
		# By default add the stack backtrace and the live stacktrace
		set stacktrace [info stacktrace]
		# omit the procedure 'errorInfo' from the stack
		lappend stacktrace {*}[stacktrace 1]
	}
	lassign $stacktrace p f l
	if {$f ne ""} {
		set result "$f:$l: Error: "
	}
	append result "$msg\n"
	append result [stackdump $stacktrace]

	# Remove the trailing newline
	string trim $result
}

# Needs to be set up by the container app (e.g. jimsh)
# Returns the empty string if unknown
proc {info nameofexecutable} {} {
	if {[exists ::jim::exe]} {
		return $::jim::exe
	}
}

# Script-based implementation of 'dict update'
proc {dict update} {&varName args script} {
	set keys {}
	foreach {n v} $args {
		upvar $v var_$v
		if {[dict exists $varName $n]} {
			set var_$v [dict get $varName $n]
		}
	}
	catch {uplevel 1 $script} msg opts
	if {[info exists varName]} {
		foreach {n v} $args {
			if {[info exists var_$v]} {
				dict set varName $n [set var_$v]
			} else {
				dict unset varName $n
			}
		}
	}
	return {*}$opts $msg
}

proc {dict replace} {dictionary {args {key value}}} {
	if {[llength ${key value}] % 2} {
		tailcall {dict replace}
	}
	tailcall dict merge $dictionary ${key value}
}

# Script-based implementation of 'dict lappend'
proc {dict lappend} {varName key {args value}} {
	upvar $varName dict
	if {[exists dict] && [dict exists $dict $key]} {
		set list [dict get $dict $key]
	}
	lappend list {*}$value
	dict set dict $key $list
}

# Script-based implementation of 'dict append'
proc {dict append} {varName key {args value}} {
	upvar $varName dict
	if {[exists dict] && [dict exists $dict $key]} {
		set str [dict get $dict $key]
	}
	append str {*}$value
	dict set dict $key $str
}

# Script-based implementation of 'dict incr'
proc {dict incr} {varName key {increment 1}} {
	upvar $varName dict
	if {[exists dict] && [dict exists $dict $key]} {
		set value [dict get $dict $key]
	}
	incr value $increment
	dict set dict $key $value
}

# Script-based implementation of 'dict remove'
proc {dict remove} {dictionary {args key}} {
	foreach k $key {
		dict unset dictionary $k
	}
	return $dictionary
}

# Script-based implementation of 'dict for'
proc {dict for} {vars dictionary script} {
	if {[llength $vars] != 2} {
		return -code error "must have exactly two variable names"
	}
	dict size $dictionary
	tailcall foreach $vars $dictionary $script
}
