lappend auto_path "./vendor"
package require websocket

proc handleConnect {chan addr port} {
    fileevent $chan readable [list handleRead $chan $addr $port]
}

proc htmlEscape {s} { string map {& "&amp;" < "&lt;" > "&gt;" "\"" "&quot;"} $s }

proc readFile {filename contentTypeVar} {
    upvar $contentTypeVar contentType
    set fd [open $filename r]
    fconfigure $fd -encoding binary -translation binary
    set response [read $fd]; close $fd; return $response
}

proc getDotAsPdf {dot contentTypeVar} {
    upvar $contentTypeVar contentType
    set contentType "application/pdf"
    set fd [open |[list dot -Tpdf <<$dot] r]
    fconfigure $fd -encoding binary -translation binary
    set response [read $fd]; close $fd; return $response
}

proc handlePage {path httpStatusVar contentTypeVar} {
    upvar $contentTypeVar contentType
    switch -exact -- $path {
        "/" {
            set l [list]
            dict for {id stmt} [Statements::all] {
                lappend l [subst {
                    <li>
                    <details>
                    <summary style="[expr {
                    [lsearch -exact [statement clause $stmt] error] != -1
                    ? "color: red"
                    : ""}]">
                    $id: [htmlEscape [statement short $stmt]]</summary>
                    <pre>[htmlEscape [statement clause $stmt]]</pre>
                    </details>
                    </li>
                }]
            }
            subst {
                <html>
                <head>
                <link rel="stylesheet" href="/style.css">
                <title>Statements</title>
                </head>
                <nav>
                <a href="/new"><button>New program</button></a>
                <a href="/programs">Running programs</a>
                <a href="/timings">Timings</a>
                <a href="/keyboards">Keyboards</a>
                <a href="/statementClauseToId.pdf">statementClauseToId graph</a>
                <a href="/statements.pdf">statements graph</a>
                </nav>
                <h1>Statements</h1>
                <ul>[join $l "\n"]</ul>
                </html>
            }
        }
        "/timings" {
            set runTimes [list]
            dict for {lambda runTime} $Evaluator::runTimesMap {
                lappend runTimes $lambda $runTime
            }
            set runTimes [lsort -integer -stride 2 -index 1 $runTimes]

            set totalRunTime 0
            set l [list]
            foreach {lambda runTime} $runTimes {
                set runCount [dict get $Evaluator::runCountsMap $lambda]
                set totalRunTime [+ $totalRunTime $runTime]
                lappend l [subst {
                    <li>
                    <pre>[htmlEscape $lambda]</pre> ($runCount runs): $runTime us
                    </li>
                }]
            }
            subst {
                <html>
                <head>
                <link rel="stylesheet" href="/style.css">
                <title>Timings</title>
                </head>
                <nav>
                <a href="/new"><button>New program</button></a>
                <a href="/">Statements</a>
                <a href="/statementClauseToId.pdf">statementClauseToId graph</a>
                <a href="/statements.pdf">statements graph</a>
                </nav>
                <h1>Timings (total frame run time $totalRunTime us)</h1>
                <ul>[join $l "\n"]</ul>
                </html>
            }
        }
        "/favicon.ico" {
            set contentType "image/x-icon"
            readFile "assets/favicon.ico" contentType
        }
        "/style.css" {
            set contentType "text/css"
            readFile "assets/style.css" contentType
        }
        "/statementClauseToId.pdf" {
            getDotAsPdf [trie dot [Statements::statementClauseToIdTrie]] contentType
        }
        "/statements.pdf" {
            getDotAsPdf [Statements::dot] contentType
        }
        "/lib/folk.js" {
            set contentType "text/javascript"
            readFile "lib/folk.js" contentType
        }
        "/vendor/gstwebrtc/gstwebrtc-api-2.0.0.min.js" {
            set contentType "text/javascript"
            readFile "vendor/gstwebrtc/gstwebrtc-api-2.0.0.min.js" contentType
        }
        "/folk_calibration_demo_video_2x_speed.mp4" {
            set contentType "video/mp4"
            readFile "assets/folk_calibration_demo_video_2x_speed.mp4" contentType
        }
        default {
            upvar $httpStatusVar httpStatus
            set httpStatus "HTTP/1.1 404 Not Found"
            subst {
                <html>
                <b>$path</b> Not found.
                </html>
            }
        }
    }
}

proc handleRead {chan addr port} {
    chan configure $chan -translation crlf
    gets $chan line; set firstline $line
    # puts "Http: $chan $addr $port: $line"
    set headers [list]
    while {[gets $chan line] >= 0 && $line ne ""} {
        if {[regexp -expanded {^( [^\s:]+ ) \s* : \s* (.+)} $line -> k v]} {
            lappend headers $k $v
        } else { break }
    }

    if {[regexp {GET ([^ ]*) HTTP/1.1} $firstline -> path] && $path ne "/ws"} {
        set response {}
        set matches [Statements::findMatches {/someone/ wishes the web server handles route /route/ with handler /handler/}]
        try {
            foreach match $matches {
                set route [dict get $match route]
                set handler [dict get $match handler]
                if {[regexp -all $route $path whole_match]} {
                    fn html {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: text/html; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    fn json {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: application/json; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    set response [apply [list {path ^html ^json} $handler] $path ${^html} ${^json}]
                }
            }
            if {$response eq ""} {
                set httpStatus "HTTP/1.1 200 OK"
                set contentType "text/html; charset=utf-8"
                set body [handlePage $path httpStatus contentType]
                if {$contentType eq "text/html; charset=utf-8"} {
                    set body [encoding convertto utf-8 $body]
                }
                set response [dict create statusAndHeaders "$httpStatus\nConnection: close\nContent-Type: $contentType\n\n" body $body]
            }
            if {![dict exists $response statusAndHeaders]} {
                error "Response not generated"
            }
        } on error e {
            set contentType "text-html; charset=utf-8"
            set body [subst {
                <html>
                <head>
                <title>folk: 500 Internal Server Error</title>
                </head>
                <body>
                <pre>[htmlEscape $e]:
[htmlEscape $::errorInfo]</pre>
                </body>
                </html>
            }]
            set response [dict create statusAndHeaders "HTTP/1.1 500 Internal Server Error\nConnection: close\nContent-Type: $contentType\n\n" body [encoding convertto utf-8 $body]]
        }
        puts -nonewline $chan [dict get $response statusAndHeaders]
        if {[dict exists $response body]} {
            chan configure $chan -encoding binary -translation binary
            puts -nonewline $chan [dict get $response body]
        }
        close $chan
    } elseif {[::websocket::test $::serverSock $chan "/ws" $headers]} {
        # puts "WS: $chan $addr $port"
        ::websocket::upgrade $chan
        # from now the handleWS will be called (not anymore handleRead).
    } else { puts "Closing: $chan $addr $port $headers"; close $chan }
}

proc handleWS {chan type msg} {
    if {$type eq "connect"} {
        Assert websocket $chan is connected
    } elseif {$type eq "close"} {
        Retract websocket $chan is connected
        Retract when websocket $chan is connected /...rest/
    } elseif {$type eq "text"} {
        eval $msg
    } elseif {$type eq "ping" || $type eq "pong" || $type eq "disconnect"} {
        # puts "Event $type from chan $chan"
    } else {
        puts "$::thisProcess: Unhandled WS event $type on $chan ($msg)"
    }
}

if {[catch {set ::serverSock [socket -server handleConnect 4273]}] == 1} {
    error "There's already a Web-capable Folk node running on this machine."
}

::websocket::server $::serverSock
::websocket::live $::serverSock /ws handleWS
