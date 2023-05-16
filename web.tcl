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

proc readPdf {dotCmd contentTypeVar} {
    upvar $contentTypeVar contentType
    set contentType "application/pdf"
    set fd [open |[list dot -Tpdf <<$dotCmd] r]
    fconfigure $fd -encoding binary -translation binary
    set response [read $fd]; close $fd; return $response
}

# TODO: Catch errors & return 501
proc handlePage {path contentTypeVar} {
    upvar $contentTypeVar contentType

    switch -exact -- $path {
        "/" {
            set l [list]
            dict for {id stmt} $Statements::statements {
                lappend l [subst {
                    <li>
                    <details>
                    <summary>$id: [htmlEscape [statement short $stmt]]</summary>
                    <pre>[htmlEscape [statement clause $stmt]]</pre>
                    </details>
                    </li>
                }]
            }
            subst {
                <html>
                <ul>
                <li><a href="/new">New program</a></li>   
                <li><a href="/timings">Timings</a></li>
                <li><a href="/statementClauseToId.pdf">statementClauseToId graph</a></li>
                <li><a href="/statements.pdf">statements graph</a></li>
                </ul>
                <ul>[join $l "\n"]</ul>
                </html>
            }
        }
        "/timings" {
            set totalTimes [list]
            dict for {body totalTime} $Evaluator::totalTimesMap {
                dict with totalTime {
                    lappend totalTimes $body [expr {$loadTime + $runTime + $unloadTime}]
                }
            }
            set totalTimes [lsort -integer -stride 2 -index 1 $totalTimes]

            set l [list]
            foreach {body totalTime} $totalTimes {
                set runs [dict get $Evaluator::runsMap $body]
                lappend l [subst {
                    <li>
                    <pre>[htmlEscape $body]</pre> ($runs runs): [dict get $Evaluator::totalTimesMap $body]: $totalTime microseconds total ([expr {$totalTime/$::stepCount}] us per frame), $runs runs ([expr {$totalTime/$runs}] us per run; [expr {$runs/$::stepCount}] runs per frame)
                    </li>
                }]
            }
            subst {
                <html>
                <h1>Timings</h1>
                <ul>[join $l "\n"]</ul>
                </html>
            }
        }
        "/favicon.ico" {
            set contentType "image/x-icon"
            readFile "assets/favicon.ico" contentType
        }
        "/statementClauseToId.pdf" {
            readPdf [trie dot $Statements::statementClauseToId] contentType
        }
        "/statements.pdf" {
            readPdf [Statements::dot] contentType
        }
        "/statementPatternToReactions.pdf" {
            readPdf [trie dot $Evaluator::statementPatternToReactions] contentType
        }
        default {
            subst {
                <html>
                <b>$path</b>
                </html>
            }
        }
    }
}


proc handleRead {chan addr port} {
    chan configure $chan -translation crlf
    gets $chan line; set firstline $line
    puts "Http: $chan $addr $port: $line"
    set headers [list]
    while {[gets $chan line] >= 0 && $line ne ""} {
        if {[regexp -expanded {^( [^\s:]+ ) \s* : \s* (.+)} $line -> k v]} {
            lappend headers $k $v
        } else { break }
    }
    if {[regexp {GET ([^ ]*) HTTP/1.1} $firstline -> path] && $path ne "/ws"} {
        set response {}
        set matches [Statements::findMatches {/someone/ wishes the web server handles route /route/ with handler /handler/}]
        foreach match $matches {
            set route [dict get $match route]
            set handler [dict get $match handler]
            if {[regexp -all $route $path whole_match]} {
                set env [dict create]
                dict set env path $path
                dict set env ^html {{body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: text/html; charset=utf-8\n\n" body $body}}
                dict set env ^json {{body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: application/json; charset=utf-8\n\n" body $body}}
                set response [Evaluator::tryRunInSerializedEnvironment $handler $env]
            }
        }
        if {$response eq ""} {
            set contentType "text/html; charset=utf-8"
            set body [handlePage $path contentType]
            set response [dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: $contentType\n\n" body $body]
        }
        if {![dict exists $response statusAndHeaders]} {
            puts -nonewline $chan "HTTP/1.1 500 Internal Server Error\nConnection: close"
        } else {
            puts -nonewline $chan [dict get $response statusAndHeaders]
            if {[dict exists $response body]} {
                chan configure $chan -encoding binary -translation binary
                puts -nonewline $chan [dict get $response body]
            }
        }
        close $chan
    } elseif {[::websocket::test $::serverSock $chan "/ws" $headers]} {
        puts "WS: $chan $addr $port"
        ::websocket::upgrade $chan
        # from now the handleWS will be called (not anymore handleRead).
    } else { puts "Closing: $chan $addr $port $headers"; close $chan }
}

proc handleWS {chan type msg} {
    if {$type eq "connect" || $type eq "ping" || $type eq "pong"} {
    } elseif {$type eq "text"} {
        if {[catch {::websocket::send $chan text [eval $msg]} err] == 1} {
            if [catch {
                puts "$::nodename: Error on receipt: $err"
                ::websocket::send $chan text $err
            } err2] { puts "$::nodename: $err2" }
        }
    } else {
        puts "$::nodename: Unhandled WS event $type $msg"
    }
}

if {[catch {set ::serverSock [socket -server handleConnect 4273]}] == 1} {
    error "There's already a Web-capable Folk node running on this machine."
}

::websocket::server $::serverSock
::websocket::live $::serverSock /ws handleWS
