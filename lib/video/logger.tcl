# video/logger.tcl
# Video logging utilities for Folk

namespace eval VideoLogger {
    variable debug 0  # Set to 0 for production, 1 for minimal logs, 2+ for verbose
    variable errorLog; array set errorLog {}
    
    # Debug flag that can be toggled externally
    proc setDebugLevel {level} {
        variable debug
        set debug $level
        log 0 "Video debug level set to $level"
    }
    
    # Enhanced logging with timestamps
    proc log {level message} {
        variable debug
        variable errorLog
        
        if {$level <= $debug} {
            # Format message with level tag
            set levelTag [lindex {ERR WARN INFO DBG} $level]
            set formattedMsg "\[VIDEO:$levelTag\] $message"
            
            # Output to stderr
            puts stderr $formattedMsg
            
            # Store recent errors and warnings
            if {$level <= 1} {
                set now [clock milliseconds]
                lappend errorLog($now) [list $level $message]
                # Keep only last 50 errors/warnings
                if {[array size errorLog] > 50} {
                    set oldestKey [lindex [lsort -integer [array names errorLog]] 0]
                    unset errorLog($oldestKey)
                }
            }
        }
    }
    
    # Get recent errors for diagnostics
    proc getRecentErrors {} {
        variable errorLog
        set result {}
        foreach timestamp [lsort -integer -decreasing [array names errorLog]] {
            foreach entry $errorLog($timestamp) {
                lappend result [list $timestamp {*}$entry]
            }
            if {[llength $result] >= 10} break
        }
        return $result
    }
    
    namespace export log setDebugLevel getRecentErrors
    namespace ensemble create
}

# Return success
return 1