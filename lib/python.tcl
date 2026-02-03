set UVX "$::env(HOME)/.local/bin/uvx"
if {![file exists $UVX]} { set UVX "uvx" }

package require oo

set cc [C]
$cc endcflags -lzmq
$cc include <zmq.h>
$cc include <string.h>

$cc code {
    static void *zmq_context = NULL;
}
$cc proc zmqInit {} void {
    if (zmq_context == NULL) {
        zmq_context = zmq_ctx_new();
    }
}

$cc proc zmqSocket {char* socketType} void* {
    zmqInit();
    int type;
    if (strcmp(socketType, "REQ") == 0) {
        type = ZMQ_REQ;
    } else if (strcmp(socketType, "REP") == 0) {
        type = ZMQ_REP;
    } else {
        Jim_SetResultString(interp, "Invalid socket type", -1);
        return NULL;
    }
    return zmq_socket(zmq_context, type);
}

$cc proc zmqBind {void* socket char* endpoint} int {
    return zmq_bind(socket, endpoint);
}

$cc proc zmqConnect {void* socket char* endpoint} int {
    return zmq_connect(socket, endpoint);
}

$cc proc zmqSendMulti {void* socket Jim_Obj* parts} void {
    int len = Jim_ListLength(interp, parts);
    for (int i = 0; i < len; i++) {
        Jim_Obj *part = Jim_ListGetIndex(interp, parts, i);
        int partLen;
        const char *partStr = Jim_GetString(part, &partLen);

        int flags = (i < len - 1) ? ZMQ_SNDMORE : 0;
        zmq_send(socket, partStr, partLen, flags);
    }
}

$cc proc zmqRecvMulti {void* socket} Jim_Obj* {
    Jim_Obj *result = Jim_NewListObj(interp, NULL, 0);
    int more = 1;

    while (more) {
        zmq_msg_t msg;
        zmq_msg_init(&msg);
        zmq_msg_recv(&msg, socket, 0);

        size_t size = zmq_msg_size(&msg);
        char *data = (char*)zmq_msg_data(&msg);

        Jim_Obj *part = Jim_NewStringObj(interp, data, size);
        Jim_ListAppendElement(interp, result, part);

        size_t more_size = sizeof(more);
        zmq_getsockopt(socket, ZMQ_RCVMORE, &more, &more_size);

        zmq_msg_close(&msg);
    }

    return result;
}

set zmq [$cc compile]

# Uvx class
class Uvx [list \
               UVX $UVX zmq $zmq \
               socket "" endpoint ""]

Uvx method constructor args {
    set endpoint "ipc:///tmp/uvx-[clock milliseconds]-[expr {int(rand() * 100000)}].ipc"

    set socket [$zmq zmqSocket REQ]
    $zmq zmqBind $socket $endpoint

    set harnessCode [subst -nocommands {
import sys
import zmq

context = zmq.Context()
socket = context.socket(zmq.REP)
socket.connect('$endpoint')

global_ns = {}
while True:
    try:
        parts = socket.recv_multipart()

        if len(parts) < 1:
            raise ValueError('Message must have at least one part (function name)')

        func_name = parts[0].decode('utf-8')
        args = [part.decode('utf-8') for part in parts[1:]]

        # Try to get function from globals, then builtins
        if func_name in global_ns:
            func = global_ns[func_name]
        elif hasattr(__builtins__, func_name):
            func = getattr(__builtins__, func_name)
        else:
            # Try to eval it
            func = eval(func_name, global_ns)

        result = func(*args)

        # Store result back in global namespace if it's callable
        if callable(result):
            global_ns[func_name] = result

        socket.send_multipart([b"ok", str(result).encode('utf-8')])

    except Exception as e:
        socket.send_multipart([b"error", str(e).encode('utf-8')])
}]

    exec $UVX --with pyzmq {*}$args \
        python -u -c $harnessCode 2>@stderr &

    # Give Python time to connect
    after 100
}

Uvx method unknown {funcName args} {
    set parts [list $funcName {*}$args]
    $zmq zmqSendMulti $socket $parts

    set response [$zmq zmqRecvMulti $socket]

    lassign $response status value
    if {$status eq "error"} { error $value }
    return $value
}
Uvx method run {code} {
    return [$self unknown "eval" $code]
}
