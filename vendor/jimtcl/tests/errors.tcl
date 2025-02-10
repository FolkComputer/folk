# Package which can generate a variety of errors at known locations

proc error_generator {type} {
	switch $type {
		badcmd {
			bogus command called
		}
		badvar {
			set bogus
		}
		error {
			error bogus
		}
		interpbadvar {
			set x "some $bogus text"
		}
		interpbadcmd {
			set x "some $bogus text"
		}
		package {
			package require dummy
		}
		source {
			source [file dirname [info script]]/dummy.tcl
		}
		badpackage {
			package require bogus
		}
		returncode {
			return -code error failure
		}
		badproc {
			error_badproc
		}
		default {
			puts "Unknown type=$type"
		}
	}
}
# line 40: Some empty lines above so that line numbers don't change
proc error_caller {type {method call}} {
	switch $method {
		call {
			error_generator $type
		}
		uplevel {
			uplevel 1 [list error_generator $type]
		}
		eval {
			eval [list error_generator $type]
		}
		evalstr {
			eval error_generator $type
		}
		default {
			puts "Unknown method=$method"
		}
	}
}

proc error_badproc {} {
	return [list missing bracket here
}
