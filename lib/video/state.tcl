# video/state.tcl
# Video state tracking and metadata for Folk

namespace eval VideoState {
    variable sources; array set sources {}
    variable metadata; array set metadata {}
    variable errorLog; array set errorLog {}
    variable debug 0  # Set to 0 for production, 1 for minimal logs, 2+ for verbose
    
    # Performance tracking
    variable stats
    array set stats {frameCount 0 cacheHits 0 lastReport 0}
    
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
    
    proc registerSource {thing source} {
        variable sources
        # Normalize path first
        if {[file exists $source]} {
            set source [file normalize $source]
        }
        set sources($thing) $source
        log 0 "Playing video: $source"
    }
    
    proc getSource {thing} {
        variable sources
        if {[info exists sources($thing)]} {return $sources($thing)}
        return ""
    }
    
    proc updateMetadata {source fps duration frames} {
        variable metadata
        if {![info exists metadata($source)]} {set metadata($source) [dict create]}
        dict set metadata($source) fps $fps
        dict set metadata($source) duration $duration
        dict set metadata($source) totalFrames $frames
        log 0 "Video metadata: $source - ${fps}fps, ${duration}s, $frames frames"
    }
    
    proc getMetadata {source} {
        variable metadata
        if {[info exists metadata($source)]} {return $metadata($source)}
        return [dict create fps 30.0 duration 1.0 totalFrames 30]
    }
    
    proc setStartTime {thing time} {
        variable metadata
        if {![info exists metadata($thing)]} {set metadata($thing) [dict create]}
        dict set metadata($thing) startTime $time
        log 0 "Set start time for $thing to $time"
    }
    
    proc getStartTime {thing {default 0}} {
        variable metadata
        if {[info exists metadata($thing)] && [dict exists $metadata($thing) startTime]} {
            return [dict get $metadata($thing) startTime]
        }
        return $default
    }
    
    # Calculate frame number with proper looping
    proc getFrameNumber {thing time} {
        set startTime [getStartTime $thing]
        if {$startTime == 0} {return 1}
        
        set relativeTime [expr {$time - $startTime}]
        if {$relativeTime < 0} {return 1}
        
        set source [getSource $thing]
        if {$source eq ""} {return 1}
        
        set sourceInfo [getMetadata $source]
        set fps [dict get $sourceInfo fps]
        set duration [dict get $sourceInfo duration]
        set totalFrames [dict get $sourceInfo totalFrames]
        
        # Enhanced looping logic with special handling for transitions
        if {$duration > 0} {
            set loopCount [expr {int($relativeTime / $duration)}]
            set loopPosition [expr {fmod($relativeTime, $duration)}]
            
            # Handle loop transitions more gracefully:
            # 1. Detect approaching loop end
            # 2. Log transition for diagnostics
            # 3. Special handling for very short videos
            variable lastLoopCount
            variable loopTransitionActive
            
            # Near the end of loop - prepare transition
            set nearEndThreshold [expr {max(0.15, min(0.3, $duration * 0.2))}]
            set isNearEnd [expr {$loopPosition > ($duration - $nearEndThreshold)}]
            
            # At beginning of loop - handle transition
            set isLoopStart [expr {$loopPosition < 0.05 && $loopCount > 0}]
            
            if {$isLoopStart} {
                # Log loop transitions (only once per loop)
                if {![info exists lastLoopCount($thing)] || $lastLoopCount($thing) != $loopCount} {
                    log 0 "LOOP DETECTED - loop #$loopCount (time=$time) - forcing transition"
                    set lastLoopCount($thing) $loopCount
                    set loopTransitionActive($thing) 1
                    
                    # Flag to ensure we actually loop in the case where we miss a frame
                    if {![info exists metadata($thing)]} {
                        set metadata($thing) [dict create]
                    }
                    dict set metadata($thing) forceLoop 1
                }
            } elseif {$loopPosition > 0.2} {
                # Clear the transition flag when we're well past the start
                set loopTransitionActive($thing) 0
                
                # Clear forced loop flag
                if {[info exists metadata($thing)] && [dict exists $metadata($thing) forceLoop]} {
                    dict unset metadata($thing) forceLoop
                }
            }
        }
        
        # Calculate frame based on position in current loop
        set frameNum [expr {int(fmod($relativeTime, $duration) * $fps) + 1}]
        
        # Apply safety margin (max 95% of total frames)
        set safeMaxFrame [expr {int($totalFrames * 0.95)}]
        if {$frameNum > $safeMaxFrame} {
            # Reset to first frame when we reach the end to ensure proper looping
            set frameNum 1
            # Log the loop boundary
            log 0 "Loop boundary reached: resetting to frame 1 from $safeMaxFrame"
        }
        if {$frameNum < 1} {set frameNum 1}
        
        # Check for forced loop situation
        if {[info exists metadata($thing)] && 
            [dict exists $metadata($thing) forceLoop] && 
            [dict get $metadata($thing) forceLoop]} {
            # If we've flagged a force loop, reset to first frame
            set frameNum 1
            log 0 "Forced loop active: sending frame 1"
        }
        
        # Simple loop transition handling
        if {[info exists loopTransitionActive($thing)] && $loopTransitionActive($thing)} {
            # All we need to do is return early frames during transitions
            set frameNum [expr {1 + int(min(5, $loopPosition * 10))}]
            log 2 "Loop transition frame: $frameNum"
        }
        
        return $frameNum
    }
    
    proc recordStats {isCache} {
        variable stats
        incr stats(frameCount)
        if {$isCache} {incr stats(cacheHits)}
        
        # Log at most once per second to avoid flooding logs
        set now [clock milliseconds]
        if {(!$isCache) || ($now - $stats(lastReport) > 1000)} {
            set hitRate [expr {$stats(frameCount) > 0 ? 
                              double($stats(cacheHits)) / $stats(frameCount) * 100.0 : 0}]
            log 0 [format "PERF: %d frames, %.1f%% cache hit rate" \
                   $stats(frameCount) $hitRate]
            set stats(lastReport) $now
        }
    }
    
    namespace export registerSource getSource updateMetadata getMetadata 
    namespace export setStartTime getStartTime getFrameNumber recordStats
    namespace export log setDebugLevel getRecentErrors
    namespace ensemble create
}

# Return success
return 1