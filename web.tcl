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

proc emitHTMLForProgramList {programList label} {
    set prettyLabel [string map {- " "} $label]
    set prettyLabel [string totitle $prettyLabel]:
    set returnList [list "<details data-label='$label' data-count='[llength $programList]'><summary>$prettyLabel ([llength $programList])</summary>"]
    lappend returnList "<ul>"
    foreach item $programList {
        lappend returnList "<li>$item</li>"
    }
    lappend returnList "</ul>"
    lappend returnList "</details>"
    join $returnList
}

proc handlePage {path httpStatusVar contentTypeVar} {
    upvar $contentTypeVar contentType
    # TODO: We can probably factor this out of web.tcl and into a separate program (web/programs.folk) while we're at it right?
    # From @osnr: https://github.com/FolkComputer/folk/pull/171#issuecomment-2292098801
    # - @cwervo 2024-09-15
    switch -exact -- $path {
        # "/statementClauseToId.pdf" {
        #     getDotAsPdf [trie dot [Statements::statementClauseToIdTrie]] contentType
        # }
        # "/statements.pdf" {
        #     getDotAsPdf [Statements::dot] contentType
        # }
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

    # TODO: Make CSS, PDF, and JS passable contentTypes to this When and default to text/html if none is provided
    if {[regexp {GET ([^ ]*) HTTP/1.1} $firstline -> path] && $path ne "/ws"} {
        set response {}
        set matches [Statements::findMatches {/someone/ wishes the web server handles route /route/ with handler /handler/}]
        try {
            puts "matches: [llength $matches]"
            foreach match $matches {
                set route [dict get $match route]
                set handler [dict get $match handler]
                if {[regexp -all $route $path whole_match]} {
                    puts "got match: $route $whole_match"
                    fn html {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: text/html; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    fn json {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: application/json; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    fn css {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: text/css; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    fn favicon {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: image/x-icon; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    fn js {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: text/javascript; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    fn pdf {body} {dict create statusAndHeaders "HTTP/1.1 200 OK\nConnection: close\nContent-Type: application/pdf; charset=utf-8\n\n" body [encoding convertto utf-8 $body]}
                    set response [apply [list {path ^html ^json ^css ^favicon ^js ^pdf} $handler] $path ${^html} ${^json} ${^css} ${^favicon} ${^js} ${^pdf}]
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