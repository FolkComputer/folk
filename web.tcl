
lappend auto_path "./vendor"
package require websocket

proc handleConnect {chan addr port} {
    fileevent $chan readable [list handleRead $chan $addr $port]
}
proc handlePage {path} {
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
            <a href="/new">New program</a>
            <ul>[join $l "\n"]</ul>
            </html>
        }]
    } elseif {$path eq "/new"} {
        return {
            <html>
            <div id="dragme" style="cursor: move; position: absolute; user-select: none; background-color: #ccc; padding: 1em">
            <textarea cols="50" rows="20" style="font-family: monospace">Wish $this is outlined blue</textarea>
            <p><button>Save</button> <button>Print</button></p>
            </div>

            <script>
// The current position of mouse
let x = 0;
let y = 0;

// Query the element
const ele = document.getElementById('dragme');

// Handle the mousedown event
// that's triggered when user drags the element
const mouseDownHandler = function (e) {
    // Get the current mouse position
    x = e.clientX;
    y = e.clientY;

    // Attach the listeners to `document`
    document.addEventListener('mousemove', mouseMoveHandler);
    document.addEventListener('mouseup', mouseUpHandler);
};

const mouseMoveHandler = function (e) {
    // How far the mouse has been moved
    const dx = e.clientX - x;
    const dy = e.clientY - y;

    // Set the position of element
    ele.style.top = `${ele.offsetTop + dy}px`;
    ele.style.left = `${ele.offsetLeft + dx}px`;

    // Reassign the position of mouse
    x = e.clientX;
    y = e.clientY;
};

const mouseUpHandler = function () {
    // Remove the handlers of `mousemove` and `mouseup`
    document.removeEventListener('mousemove', mouseMoveHandler);
    document.removeEventListener('mouseup', mouseUpHandler);
};

ele.addEventListener('mousedown', mouseDownHandler);
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
    if {[regexp {GET ([^ ]*) HTTP/1.1} $firstline -> path] && $path ne "/ws"} {
        puts -nonewline $chan "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: text/html; charset=utf-8\r\n\r\n"
        puts -nonewline $chan [handlePage $path]
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
