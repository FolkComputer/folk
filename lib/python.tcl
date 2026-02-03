set UVX "$::env(HOME)/.local/bin/uvx"
if {![file exists $UVX]} { set UVX "uvx" }

package require oo
source lib/mpack.tcl

class Uvx [list \
               UVX $UVX mpack $mpack \
               socket "" endpoint ""]
Uvx method constructor args {
    set endpoint "ipc:///tmp/uvx-[clock milliseconds]-[expr {int(rand() * 100000)}].ipc"

    set socket [$mpack zmqSocket REQ]
    $mpack zmqBind $socket $endpoint

    set harnessCode [subst -nocommands {
import sys
import zmq
import msgpack

context = zmq.Context()
socket = context.socket(zmq.REP)
socket.connect('$endpoint')

while True:
    try:
        msg_bytes = socket.recv()
        msg = msgpack.unpackb(msg_bytes, raw=False)

        if not isinstance(msg, list) or len(msg) < 1:
            raise ValueError('Message must be a list with at least one element')

        func_name = msg[0]
        args = msg[1:] if len(msg) > 1 else []

        func = getattr(__builtins__, func_name, None) or \
            getattr(locals(), func_name, None) or \
            getattr(globals(), func_name, None)
        result = func(*args)
        socket.send(msgpack.packb({'status': 'ok', 'result': result}))

    except Exception as e:
        print(f"python: Error: {func_name}({args}): {e}", file=sys.stderr)
        socket.send(msgpack.packb({'status': 'error', 'error': str(e)}))
}]

    exec $UVX --with msgpack --with pyzmq {*}$args \
        python -u -c $harnessCode 2>@stderr &

    # Give Python time to connect
    after 100
}
Uvx method call {funcName args} {
    set msg [list $funcName {*}$args]
    $mpack zmqSend $socket $msg

    set response [$mpack zmqRecv $socket]

    # Response is a dict-like list: status ok/error result/error value
    set status_idx [lsearch $response "status"]
    if {$status_idx == -1} {
        error "Invalid response from Python"
    }
    set status [lindex $response [expr {$status_idx + 1}]]

    if {$status eq "error"} {
        set error_idx [lsearch $response "error"]
        set error_msg [lindex $response [expr {$error_idx + 1}]]
        error $error_msg
    }

    set result_idx [lsearch $response "result"]
    if {$result_idx == -1} {
        return ""
    }
    return [lindex $response [expr {$result_idx + 1}]]
}
Uvx method run {code} {
    return [$self call "eval" $code]
}
