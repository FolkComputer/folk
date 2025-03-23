# video-utils.tcl
# Video Utilities for Folk - Modular implementation
# Handles video decoding, frame extraction, and caching

# Determine our base directory
set video_lib_dir [file dirname [info script]]
set video_dir [file join $video_lib_dir "video"]

# Check if the video directory exists, create it if not
if {![file exists $video_dir]} {
    error "Video components directory not found: $video_dir"
}

# Load all component modules in the correct order
set modules {
    "logger.tcl"
    "state.tcl"
    "decoder.tcl"
}

foreach module $modules {
    set module_path [file join $video_dir $module]
    
    if {![file exists $module_path]} {
        error "Missing video module: $module_path"
    }
    
    # Source the module and check for successful loading
    if {[catch {source $module_path} err]} {
        error "Failed to load video module $module: $err"
    }
}

# Return the version for inclusion check
return 1.0