proc audioSystemParseAplayPlayback {text} {
    set devices [list]
    foreach line [split $text "\n"] {
        if {![regexp {^card ([0-9]+): ([^ ]+) \[([^\]]*)\], device ([0-9]+): ([^\[]+)\[([^\]]*)\]} \
                  $line -> card cardName cardLabel device deviceName deviceLabel]} {
            continue
        }

        lappend devices [dict create \
            card $card \
            cardName [string trim $cardName] \
            cardLabel [string trim $cardLabel] \
            device $device \
            deviceName [string trim $deviceName] \
            deviceLabel [string trim $deviceLabel] \
            raw $line]
    }
    return $devices
}

proc audioSystemDeviceText {device} {
    set parts [list]
    foreach key {cardName cardLabel deviceName deviceLabel eldMonitorName raw} {
        if {[dict exists $device $key]} {
            lappend parts [dict get $device $key]
        }
    }
    return [string toupper [join $parts " "]]
}

proc audioSystemDeviceReason {device} {
    set text [audioSystemDeviceText $device]
    set connectedEld [expr {
        [dict getdef $device eldMonitorPresent 0] &&
        [dict getdef $device eldValid 0]
    }]
    if {$connectedEld} {
        return connected-hdmi
    }
    if {[string first "HDMI" $text] >= 0 || [string first "DISPLAYPORT" $text] >= 0} {
        return hdmi
    }
    if {[string first "ANALOG" $text] >= 0} {
        return analog
    }
    return first-playback
}

proc audioSystemDeviceScore {device} {
    switch -- [audioSystemDeviceReason $device] {
        connected-hdmi { return 400 }
        hdmi { return 200 }
        analog { return 100 }
        first-playback { return 10 }
        default { return 10 }
    }
}

proc audioSystemJackDeviceName {device} {
    set cardName [dict get $device cardName]
    set deviceNumber [dict get $device device]
    if {$cardName ne ""} {
        return "hw:CARD=$cardName,DEV=$deviceNumber"
    }
    return "hw:[dict get $device card],$deviceNumber"
}

proc audioSystemParseEldText {path text} {
    set info [dict create path $path eldMonitorPresent 0 eldValid 0 eldMonitorName ""]
    foreach line [split $text "\n"] {
        if {![regexp {^([^[:space:]]+)[[:space:]]+(.+)$} $line -> key value]} {
            continue
        }

        set value [string trim $value]
        switch -- $key {
            monitor_present {
                dict set info eldMonitorPresent [expr {$value eq "1"}]
            }
            eld_valid {
                dict set info eldValid [expr {$value eq "1"}]
            }
            monitor_name {
                dict set info eldMonitorName $value
            }
        }
    }
    return $info
}

proc audioSystemReadTextFile {path} {
    if {[catch {
        set fh [open $path r]
        set text [read $fh]
        close $fh
        set text
    } text]} {
        return ""
    }
    return $text
}

proc audioSystemReadEldEntries {{root /proc/asound}} {
    set entries [dict create]
    foreach cardDir [lsort -dictionary [glob -nocomplain [file join $root card*]]] {
        if {![regexp {^card([0-9]+)$} [file tail $cardDir] -> card]} {
            continue
        }

        set cardEntries [list]
        foreach eldPath [lsort -dictionary [glob -nocomplain [file join $cardDir {eld#*}]]] {
            set text [audioSystemReadTextFile $eldPath]
            lappend cardEntries [audioSystemParseEldText $eldPath $text]
        }
        if {[llength $cardEntries] > 0} {
            dict set entries $card $cardEntries
        }
    }
    return $entries
}

proc audioSystemAttachEldInfo {devices eldEntries} {
    set devicesWithEld [list]
    set hdmiIndexByCard [dict create]

    foreach device $devices {
        set card [dict get $device card]
        set cardIndex [dict getdef $hdmiIndexByCard $card 0]
        set text [audioSystemDeviceText $device]
        if {[string first "HDMI" $text] >= 0 || [string first "DISPLAYPORT" $text] >= 0} {
            if {[dict exists $eldEntries $card]} {
                set cardElds [dict get $eldEntries $card]
                if {$cardIndex < [llength $cardElds]} {
                    set eld [lindex $cardElds $cardIndex]
                    foreach key {eldMonitorPresent eldValid eldMonitorName} {
                        if {[dict exists $eld $key]} {
                            dict set device $key [dict get $eld $key]
                        }
                    }
                }
            }
            dict set hdmiIndexByCard $card [expr {$cardIndex + 1}]
        }
        lappend devicesWithEld $device
    }

    return $devicesWithEld
}

proc audioSystemSelectJackDevice {aplayOutput {override ""} {eldEntries ""}} {
    set override [string trim $override]
    if {$override ne ""} {
        return [dict create device $override reason override]
    }

    set best ""
    set bestScore -1
    foreach device [audioSystemAttachEldInfo [audioSystemParseAplayPlayback $aplayOutput] $eldEntries] {
        set score [audioSystemDeviceScore $device]
        if {$score > $bestScore} {
            set best $device
            set bestScore $score
        }
    }

    if {$best eq ""} {
        return [dict create device default reason fallback-default]
    }

    return [dict create \
        device [audioSystemJackDeviceName $best] \
        reason [audioSystemDeviceReason $best] \
        card [dict get $best card] \
        cardName [dict get $best cardName] \
        deviceNumber [dict get $best device] \
        label [dict get $best deviceLabel] \
        eldMonitorPresent [dict getdef $best eldMonitorPresent 0] \
        eldValid [dict getdef $best eldValid 0] \
        eldMonitorName [dict getdef $best eldMonitorName ""]]
}

fn audioSystemPortExists {ports port} {
    return [expr {[lsearch -exact $ports $port] >= 0}]
}

fn audioSystemPlanJackLink {ports source dest} {
    fn audioSystemPortExists
    if {![audioSystemPortExists $ports $source] || ![audioSystemPortExists $ports $dest]} {
        return ""
    }
    return [list $source $dest]
}

fn audioSystemAppendJackLink {linksVar ports source dest} {
    fn audioSystemPlanJackLink
    upvar 1 $linksVar links
    set link [audioSystemPlanJackLink $ports $source $dest]
    if {$link ne "" && [lsearch -exact $links $link] < 0} {
        lappend links $link
    }
}

fn audioSystemPortsMatching {ports pattern} {
    set matching [list]
    foreach port $ports {
        if {[string match $pattern $port]} {
            lappend matching $port
        }
    }
    return $matching
}

fn audioSystemHasVolumePorts {ports} {
    fn audioSystemPortExists
    foreach port {folk-volume:in_1 folk-volume:in_2 folk-volume:out_1 folk-volume:out_2} {
        if {![audioSystemPortExists $ports $port]} {
            return false
        }
    }
    return true
}

fn audioSystemAppendJackBypassDisconnects {linksVar ports sourcePattern} {
    fn audioSystemAppendJackLink
    fn audioSystemPortsMatching
    upvar 1 $linksVar links
    foreach source [audioSystemPortsMatching $ports $sourcePattern] {
        foreach dest [audioSystemPortsMatching $ports "system:playback_*"] {
            audioSystemAppendJackLink links $ports $source $dest
        }
    }
}

fn audioSystemJackConnectionPlan {ports sourceL sourceR {sourcePattern ""}} {
    fn audioSystemAppendJackBypassDisconnects
    fn audioSystemAppendJackLink
    fn audioSystemHasVolumePorts
    set connect [list]
    set disconnect [list]

    if {[audioSystemHasVolumePorts $ports]} {
        audioSystemAppendJackLink connect $ports $sourceL folk-volume:in_1
        audioSystemAppendJackLink connect $ports $sourceR folk-volume:in_2
        audioSystemAppendJackLink connect $ports folk-volume:out_1 system:playback_1
        audioSystemAppendJackLink connect $ports folk-volume:out_2 system:playback_2
        if {$sourcePattern ne ""} {
            audioSystemAppendJackBypassDisconnects disconnect $ports $sourcePattern
        } else {
            audioSystemAppendJackLink disconnect $ports $sourceL system:playback_1
            audioSystemAppendJackLink disconnect $ports $sourceR system:playback_2
        }
    } else {
        audioSystemAppendJackLink connect $ports $sourceL system:playback_1
        audioSystemAppendJackLink connect $ports $sourceR system:playback_2
    }

    return [dict create connect $connect disconnect $disconnect]
}

proc audioSystemParseJackdArgs {jackdCommand} {
    set runtime [dict create command $jackdCommand]
    set tokens [split $jackdCommand]

    for {set i 0} {$i < [llength $tokens]} {incr i} {
        set token [lindex $tokens $i]
        set value ""

        if {[lsearch -exact {-d -r -p -n} $token] >= 0} {
            if {$i + 1 >= [llength $tokens]} {
                continue
            }
            incr i
            set value [lindex $tokens $i]
        } elseif {[regexp {^-(d|r|p|n)(.+)$} $token -> optionValue attachedValue]} {
            set token "-$optionValue"
            set value $attachedValue
        } else {
            continue
        }

        switch -- $token {
            -d {
                if {![dict exists $runtime driver]} {
                    dict set runtime driver $value
                } elseif {[dict get $runtime driver] eq "alsa"} {
                    dict set runtime device $value
                } elseif {![dict exists $runtime device]} {
                    dict set runtime device $value
                }
            }
            -r {
                dict set runtime sampleRate $value
            }
            -p {
                dict set runtime periodSize $value
            }
            -n {
                dict set runtime periods $value
            }
        }
    }

    return $runtime
}
