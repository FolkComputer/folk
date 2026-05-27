fn folkDependencyPathEntries {{path ""}} {
    if {$path eq ""} {
        if {![info exists ::env(PATH)]} {
            return [list]
        }
        set path $::env(PATH)
    }
    return [split $path :]
}

fn folkDependencyFindCommand {cmd {path ""}} {
    if {[string first "/" $cmd] >= 0} {
        if {[file executable $cmd] && ![file isdirectory $cmd]} {
            return $cmd
        }
        return ""
    }

    foreach dir [folkDependencyPathEntries $path] {
        if {$dir eq ""} {
            set dir .
        }
        set candidate [file join $dir $cmd]
        if {[file executable $candidate] && ![file isdirectory $candidate]} {
            return $candidate
        }
    }
    return ""
}

fn folkDependencyCommandStatus {cmd {path ""}} {
    set found [folkDependencyFindCommand $cmd $path]
    if {$found eq ""} {
        return [dict create available false path ""]
    }
    return [dict create available true path $found]
}

fn folkDependencyCommandAvailable {cmd {path ""}} {
    return [dict get [folkDependencyCommandStatus $cmd $path] available]
}

fn folkDependencyCommandPath {cmd {path ""}} {
    return [dict get [folkDependencyCommandStatus $cmd $path] path]
}
