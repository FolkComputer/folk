
lappend auto_path "./vendor"
package require websocket

proc convertToJsonString {results} {
    # convert {color palegoldenrod __matcheeId 10} {color magenta __matcheeId 31}
    # into [{"color": "palegoldenrod", "__matcheeId": "10"}, {"color": "magenta", "__matcheeId": "31"}]
    set resultStrList [list]
    foreach result $results {
        set resultStr [list]
        foreach {k v} $result {
            lappend resultStr "\"$k\": \"$v\""
        }
        lappend resultStrList "{[join $resultStr ", "]}"
    }
    set hackJsonString "\[[join $resultStrList ", "]\]"
    puts "$::nodename: findMatches results str: $hackJsonString"
    return $hackJsonString
}
proc uriDecode {uri} {
    return [string map {"%2F" "/"} [string map {"%20" " "} $uri]]
}
proc handleConnect {chan addr port} {
    fileevent $chan readable [list handleRead $chan $addr $port]
}
proc handlePage {path contentTypeVar extraResponseHeadersStringVar} {
    upvar $contentTypeVar contentType
    upvar $extraResponseHeadersStringVar extraResponseHeadersString
    set findMatchUrlPrefix "/findMatches?q="
    if {$path eq "/"} {
        set l [list]
        dict for {id stmt} $Statements::statements {
            lappend l [subst {
                <li>
                <details>
                <summary>$id: [statement short $stmt]</summary>
                <pre>[statement clause $stmt]</pre>
                </details>
                </li>
            }]
        }
        return [subst {
            <html>
            <ul>
            <li><a href="/new">New program</a></li>
            <li><a href="/statementClauseToId.pdf">statementClauseToId graph</a></li>
            <li><a href="/statements.pdf">statements graph</a></li>
            </ul>
            <ul>[join $l "\n"]</ul>
            </html>
        }]
    } elseif {$path eq "/statementClauseToId.pdf"} {
        set contentType "application/pdf"
        set fd [open |[list dot -Tpdf <<[trie dot $Statements::statementClauseToId]] r]
        fconfigure $fd -encoding binary -translation binary
        set response [read $fd]; close $fd; return $response
    } elseif {$path eq "/statements.pdf"} {
        set contentType "application/pdf"
        set fd [open |[list dot -Tpdf <<[Statements::dot]] r]
        fconfigure $fd -encoding binary -translation binary
        set response [read $fd]; close $fd; return $response
    } elseif {[string first $findMatchUrlPrefix $path] != -1} {
        set contentType "application/json"
        set queryEncoded [regsub ***=$findMatchUrlPrefix $path ""]
        puts "$::nodename: findMatches: $queryEncoded"
        # TODO: full URL decoding https://wiki.tcl-lang.org/page/url-encoding
        set pattern [uriDecode $queryEncoded]
        # set pattern {/someone/ wishes /thing/ is outlined /color/}
        puts "$::nodename: findMatches pattern: $pattern"
        set results [Statements::findMatches $pattern]
        puts "$::nodename: findMatches results: $results"
        set resultStr [convertToJsonString $results]
        set contentLength [string length $resultStr]
        set extraResponseHeadersString "Content-Length: $contentLength"
        return $resultStr
    } elseif {$path eq "/new"} {
        return {
            <html>
            <span id="status">Status</span>
            <div id="dragme" style="cursor: move; position: absolute; user-select: none; background-color: #ccc; padding: 1em">
            <textarea id="code" cols="50" rows="20" style="font-family: monospace">Wish $this is outlined blue</textarea>
            <p><button onclick="handleSave()">Save</button> <button onclick="handlePrint()">Print</button><button id="printback" style="font-size: 50%; display: none" onclick="handlePrintBack()">Print Back</button></p>
            </div>

            <script>
// The current position of mouse
let x = 0;
let y = 0;

// Query the element
const ele = document.getElementById('dragme');
const codeEle = document.getElementById("code");

// Handle the mousedown event
// that's triggered when user drags the element
const mouseDownHandler = function (e) {
    if (e.target == codeEle) return;

    // Get the current mouse position
    x = e.clientX;
    y = e.clientY;

    // Attach the listeners to `document`
    document.addEventListener('mousemove', mouseMoveHandler);
    document.addEventListener('mouseup', mouseUpHandler);
};

const mouseMoveHandler = function (e) {
    if (e.target == codeEle) return;

    // How far the mouse has been moved
    const dx = e.clientX - x;
    const dy = e.clientY - y;

    // Set the position of element
    const [top, left] = [ele.offsetTop + dy, ele.offsetLeft + dx];
    ele.style.top = `${top}px`;
    ele.style.left = `${left}px`;
    handleDrag();

    // Reassign the position of mouse
    x = e.clientX;
    y = e.clientY;
};

const mouseUpHandler = function () {
    // Remove the handlers of `mousemove` and `mouseup`
    document.removeEventListener('mousemove', mouseMoveHandler);
    document.removeEventListener('mouseup', mouseUpHandler);
};

// Cmd + S || Ctrl + S => Save
document.addEventListener('keydown', function(e) {
  if ((window.navigator.platform.match('Mac') ? e.metaKey : e.ctrlKey)  && e.keyCode == 83) {
    e.preventDefault();
    handleSave();
  }
}, false);
// Cmd + P || Ctrl + P => Print
document.addEventListener('keydown', function(e) {
  if ((window.navigator.platform.match('Mac') ? e.metaKey : e.ctrlKey)  && e.keyCode == 80) {
    e.preventDefault();
    handlePrint();
  }
}, false);

ele.addEventListener('mousedown', mouseDownHandler);
</script>

<script>
const program = String(Math.random());

let ws;
let send;
function wsConnect() {
    ws = new WebSocket(window.location.origin.replace("http", "ws") + "/ws");
    send = function(s) { ws.send(s); }

    ws.onopen = () => {
        document.getElementById('status').innerHTML = "<span style=background-color:seagreen;color:white;>Connnected</span>";

        handleDrag();
    };
    ws.onclose = window.onbeforeunload = () => {
        document.getElementById('status').innerHTML = "<span style=background-color:red;color:white;>Disconnnected</span>";

        send(`Retract web claims {${program}} has region /something/`);
        send(`Retract web claims {${program}} has program code /something/`);
        setTimeout(() => { wsConnect(); }, 1000);
    };
    ws.onerror = (err) => {
        document.getElementById('status').innerText = "Error";
        console.error('Socket encountered error: ', err.message, 'Closing socket');
        ws.close();
    }
};
wsConnect();

function handleDrag() {
  const [top, left, w, h] = [ele.offsetTop, ele.offsetLeft, ele.offsetWidth, ele.offsetHeight];
    send(`
proc handleConfigure {program x y w h} {
        set vertices [list [list $x $y] \
                          [list [expr {$x+$w}] $y] \
                          [list [expr {$x+$w}] [expr {$y+$h}]] \
                          [list $x [expr {$y+$h}]]]
        set edges [list [list 0 1] [list 1 2] [list 2 3] [list 3 0]]
        Retract web claims $program has region /something/
        Assert web claims $program has region [list $vertices $edges]
}
handleConfigure {${program}} {${left}} {${top}} {${w}} {${h}}
    `);
}
function handleSave() {
    const code = document.getElementById("code").value;
    send(`Retract web claims {${program}} has program code /something/`);
    send(`Assert web claims {${program}} has program code {${code}}`);
}
let jobid;
function handlePrint() {
    const code = document.getElementById("code").value;
    jobid = String(Math.random());
    send(`Assert web wishes to print {${code}} with job id {${jobid}}`);
    setTimeout(500, () => {
      send(`Retract web wishes to print {${code}} with job id {${jobid}}`);
    });
    document.getElementById('printback').style.display = '';
}
function handlePrintBack() {
    send(`Assert web wishes to print the back of job id {${jobid}}`);
    setTimeout(500, () => {
      send(`Retract web wishes to print the back of job id {${jobid}}`);
    });
}
</script>
            </html>
        }
    }

    subst {
        <html>
        <b>$path</b>
        </html>
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
    if {[regexp {GET ([^ ]*) HTTP/1..} $firstline -> path] && $path ne "/ws"} {
        set contentType "text/html; charset=utf-8"
        set extraResponseHeadersString ""
        set response [handlePage $path contentType extraResponseHeadersString]
        puts -nonewline $chan "HTTP/1.1 200 OK\nConnection: close\nContent-Type: $contentType\n$extraResponseHeadersString\n\n"
        chan configure $chan -encoding binary -translation binary
        puts -nonewline $chan $response
        close $chan
    } elseif {[regexp {POST ([^ ]*) HTTP/1..} $firstline -> path] && $path ne "/ws"} {
        set contentType "text/html; charset=utf-8"
        set response "OK"
        puts $headers
        set contentLengthHeaderIndex [lsearch -exact $headers "Content-Length"]
        if {$contentLengthHeaderIndex >= 0} {
            set contentLengthHeaderIndex [lindex $headers [expr $contentLengthHeaderIndex + 1]]
            set data [read $chan $contentLengthHeaderIndex]
            puts "Got data:"
            puts $data
            # claim=sensor%20value%20is%206&retract=sensor%20value%20is%20%2Fvalue%2F
            # becomes dict: claim sensor%20value%20is%206 retract sensor%20value%20is%20%2Fvalue%2F
            set x [split $data "&="]
            puts $x
            set retractStr ""
            set claimStr ""
            foreach {k v} $x {
                if {$k eq "retract"} {
                    set retractStr [uriDecode $v]
                } elseif {$k eq "claim"} {
                    set claimStr [uriDecode $v]
                }
            }
            puts "retract: $retractStr"
            puts "claim: $claimStr"
            eval "Retract $retractStr"
            eval "Assert $claimStr"
            Step
            Statements::print
        }
        puts -nonewline $chan "HTTP/1.1 200 OK\nConnection: close\nContent-Type: $contentType\n\n"
        chan configure $chan -encoding binary -translation binary
        puts -nonewline $chan $response
        close $chan
    } elseif {[::websocket::test $::serverSock $chan "/ws" $headers]} {
        puts "WS: $chan $addr $port"
        ::websocket::upgrade $chan
        # from now the handleWS will be called (not anymore handleRead).
    } else { puts "Closing: $chan $addr $port $headers"; close $chan }
}
proc handleWS {chan type msg} {
    if {$type eq "text"} {
        if {[catch {::websocket::send $chan text [eval $msg]} err] == 1} {
            if [catch {
                puts "$::nodename: Error on receipt: $err"
                ::websocket::send $chan text $err
            } err2] { puts "$::nodename: $err2" }
        }
    }
}

if {[catch {set ::serverSock [socket -server handleConnect 4273]}] == 1} {
    set ::nodename "[info hostname]-1"
    puts "$::nodename: Note: There's already a Folk node running on this machine."
    set ::serverSock [socket -server handleConnect 4274]
}
::websocket::server $::serverSock
::websocket::live $::serverSock /ws handleWS
