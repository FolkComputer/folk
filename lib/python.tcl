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
               functions [dict create] \
               registeredArgtypes [dict create]]

Uvx method constructor args {
    set endpoint "ipc:///tmp/uvx-[clock milliseconds]-[expr {int(rand() * 100000)}].ipc"

    set socket [$zmq zmqSocket REQ]
    $zmq zmqBind $socket $endpoint

    set harnessCode [subst -nocommands -nobackslashes {
import sys
import zmq
import json

context = zmq.Context()
socket = context.socket(zmq.REP)
socket.connect('$endpoint')

# Storage for argtype deserializers and function signatures
registered_argtypes = {}
def __register_argtype__(type_name, deserializer_code):
    # Store deserializer as a function that takes socket
    # Indent the deserializer code and wrap in a function
    indented = '\n'.join('    ' + line for line in deserializer_code.split('\n'))
    func_code = f"def _deserialize_{type_name}(socket):\n{indented}"
    exec(func_code, globals())
    registered_argtypes[type_name] = globals()[f'_deserialize_{type_name}']

fn_signatures = {}
def __register_function__(fn_name, *fn_argtypes):
    fn_signatures[fn_name] = fn_argtypes

while True:
    try:
        # Read function name
        fn_name = socket.recv().decode('utf-8')

        # Look up function in globals, locals, or builtins
        func = (globals().get(fn_name) or
                locals().get(fn_name) or
                getattr(__builtins__, fn_name, None))

        if func is None:
            raise NameError(f"name '{fn_name}' is not defined")

        # Parse arguments based on function signature if available
        parsed_args = []
        if fn_name in fn_signatures:
            fn_argtypes = fn_signatures[fn_name]
            for argtype in fn_argtypes:
                if argtype in registered_argtypes:
                    # Use registered deserializer, giving it direct socket access
                    deserialized = argtypes[arg_type](socket)
                    parsed_args.append(deserialized)
                else:
                    # Standard JSON decode
                    arg = socket.recv()
                    try:
                        parsed_args.append(json.loads(arg))
                    except (json.JSONDecodeError, ValueError):
                        parsed_args.append(arg)
            # Consume terminator
            socket.recv()
        else:
            # No signature info, read until terminator
            # Pass arguments as strings without JSON parsing for safety
            more = socket.getsockopt(zmq.RCVMORE)
            while more:
                arg = socket.recv()
                more = socket.getsockopt(zmq.RCVMORE)
                if more or len(arg) > 0:  # Not the terminator
                    parsed_args.append(arg.decode('utf-8'))

        result = func(*parsed_args)
        socket.send_multipart([b"ok", str(result).encode('utf-8')])

    except Exception as e:
        import traceback
        socket.send_multipart([b"error", traceback.format_exc().encode('utf-8')])
}]

    exec $UVX --with pyzmq {*}$args \
        python -u -c $harnessCode 2>@stderr &

    # Give Python time to connect
    after 100
}

Uvx method unknown {fnName args} {
    # Send function name first
    $zmq zmqSendMore $socket $fnName

    # Check if this function has registered types
    if {[dict exists $functions $fnName]} {
        set funcInfo [dict get $functions $fnName]
        set argTypes [dict get $funcInfo argTypes]

        # Send each argument according to its type
        foreach schema $argTypes arg $args {
            # Check if this is a custom argtype
            if {[dict exists $registeredArgtypes $schema]} {
                set serializerCode [dict get $registeredArgtypes $schema]
                apply [list {zmq socket arg} $serializerCode] $zmq $socket $arg
            } else {
                # Use JSON encoding
                set encoded [json::encode $arg $schema]
                $zmq zmqSendMore $socket $encoded
            }
        }
        
    } else {
        # No type info, send args as strings
        foreach arg $args { $zmq zmqSendMore $socket $arg }
    }

    # Send terminator.
    $zmq zmqSend $socket "" 0

    set response [$zmq zmqRecvMulti $socket]

    lassign $response status value
    if {$status eq "error"} { error $value }
    return $value
}
Uvx method run {code} {
    return [$self unknown "eval" $code]
}

Uvx method argtype {typeName serializer deserializer} {
    # Store the Tcl serializer
    dict set registeredArgtypes $typeName $serializer

    # Register the Python deserializer with Python
    $zmq zmqSendMore $socket "__register_argtype__"
    $zmq zmqSendMore $socket $typeName
    $zmq zmqSendMore $socket $deserializer
    $zmq zmqSend $socket "" 0

    set response [$zmq zmqRecvMulti $socket]
    lassign $response status value
    if {$status eq "error"} { error $value }
}

Uvx method def {fnName argSpec body} {
    # Parse argument specification: {Type1 name1 Type2 name2 ...}
    set argNames {}
    set argTypes {}
    foreach {argType argName} $argSpec {
        lappend argNames $argName
        lappend argTypes $argType
    }

    # Store function metadata
    dict set functions $fnName [dict create \
        argNames $argNames \
        argTypes $argTypes]

    # Register function signature with Python
    $self __register_function__ $fnName {*}$argTypes

    set response [$zmq zmqRecvMulti $socket]
    lassign $response status value
    if {$status eq "error"} { error $value }

    # Create Python function
    set pythonArgs [join $argNames ", "]
    set pythonDef "def $fnName\($pythonArgs):\n"

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
