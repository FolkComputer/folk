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

$cc proc zmqSend {void* socket char* data int flags} int {
    return zmq_send(socket, data, strlen(data), flags);
}

$cc proc zmqSendMore {void* socket char* data} int {
    return zmq_send(socket, data, strlen(data), ZMQ_SNDMORE);
}

$cc proc zmqSendBytes {void* socket Jim_Obj* data int flags} int {
    int len;
    const char *bytes = Jim_GetString(data, &len);
    return zmq_send(socket, bytes, len, flags);
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
               socket "" endpoint "" \
               functions {} \
               argtypes {}]

Uvx method constructor args {
    set functions [dict create]
    set argtypes [dict create]
    set endpoint "ipc:///tmp/uvx-[clock milliseconds]-[expr {int(rand() * 100000)}].ipc"

    set socket [$zmq zmqSocket REQ]
    $zmq zmqBind $socket $endpoint

    set harnessCode [subst -nocommands {
import sys
import zmq
import json

context = zmq.Context()
socket = context.socket(zmq.REP)
socket.connect('$endpoint')

while True:
    try:
        parts = socket.recv_multipart()

        if len(parts) < 1:
            raise ValueError('Message must have at least one part (function name)')

        func_name = parts[0].decode('utf-8')
        args = [part.decode('utf-8') for part in parts[1:]]

        # Look up function in globals, locals, or builtins
        func = (globals().get(func_name) or
                locals().get(func_name) or
                getattr(__builtins__, func_name, None))

        if func is None:
            raise NameError(f"name '{func_name}' is not defined")

        # For user-defined functions (not builtins), try to parse JSON arguments
        if not hasattr(__builtins__, func_name):
            parsed_args = []
            for arg in args:
                try:
                    parsed_args.append(json.loads(arg))
                except (json.JSONDecodeError, ValueError):
                    # Not JSON, use as string
                    parsed_args.append(arg)
            args = parsed_args

        result = func(*args)
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
    # Send function name first
    if {[llength $args] > 0} {
        $zmq zmqSendMore $socket $funcName
    } else {
        $zmq zmqSend $socket $funcName 0
    }

    # Check if this function has registered types
    if {[dict exists $functions $funcName]} {
        set funcInfo [dict get $functions $funcName]
        set argTypes [dict get $funcInfo argTypes]

        # Send each argument according to its type
        set numArgs [llength $args]
        set i 0
        foreach schema $argTypes arg $args {
            incr i
            set isLast [expr {$i == $numArgs}]
            set flags [expr {$isLast ? 0 : 0x01}]

            # Check if this is a custom argtype
            if {[dict exists $argtypes $schema]} {
                set serializerCode [dict get $argtypes $schema]
                # Evaluate the serializer code with $arg, $socket, $flags, and $zmq in scope
                set zmq $zmq
                set socket $socket
                set arg $arg
                set flags $flags
                eval $serializerCode
            } else {
                # Use JSON encoding
                set encoded [json::encode $arg $schema]
                $zmq zmqSendBytes $socket $encoded $flags
            }
        }
    } else {
        # No type info, send args as strings
        set numArgs [llength $args]
        set i 0
        foreach arg $args {
            incr i
            set isLast [expr {$i == $numArgs}]
            set flags [expr {$isLast ? 0 : 0x01}]
            $zmq zmqSend $socket $arg $flags
        }
    }

    set response [$zmq zmqRecvMulti $socket]

    lassign $response status value
    if {$status eq "error"} { error $value }
    return $value
}
Uvx method run {code} {
    return [$self unknown "eval" $code]
}

Uvx method argtype {typeName serializer} {
    dict set argtypes $typeName $serializer
}

Uvx method def {funcName argSpec body} {
    # Parse argument specification: {Type1 name1 Type2 name2 ...}
    set argNames {}
    set argTypes {}
    foreach {argType argName} $argSpec {
        lappend argNames $argName
        lappend argTypes $argType
    }

    # Store function metadata
    dict set functions $funcName [dict create \
        argNames $argNames \
        argTypes $argTypes]

    # Create Python function
    set pythonArgs [join $argNames ", "]
    set pythonDef "def $funcName\($pythonArgs):\n"

    # Strip common leading whitespace from body (like textwrap.dedent)
    set lines [split $body "\n"]

    # Find minimum indentation (excluding empty lines)
    set minIndent 999
    foreach line $lines {
        if {[string trim $line] ne ""} {
            set leadingSpaces [expr {[string length $line] - [string length [string trimleft $line]]}]
            if {$leadingSpaces < $minIndent} {
                set minIndent $leadingSpaces
            }
        }
    }

    # Remove common indentation and add function body indentation
    set indentedBody ""
    foreach line $lines {
        set trimmedLine [string trim $line]
        if {$trimmedLine ne ""} {
            set dedented [string range $line $minIndent end]
            append indentedBody "    $dedented\n"
        }
    }

    # If body is empty, add pass statement
    if {$indentedBody eq ""} {
        set indentedBody "    pass\n"
    }

    set pythonCode "$pythonDef$indentedBody"

    $self exec $pythonCode
}
