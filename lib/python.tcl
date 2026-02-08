set UVX "$::env(HOME)/.local/bin/uvx"
if {![file exists $UVX]} { set UVX "uvx" }

set cc [C]
$cc endcflags -lzmq
$cc include <zmq.h>
$cc include <pthread.h>
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

# These need to be maintained in C so that they can be written and
# read from multiple threads (any thread may call into the Python
# module at any time).
$cc code {
    // This C module is global, so we need to maintain a separate
    // functions/registeredArgtypes per uvx (per socket).

    typedef struct SocketStringKV {
        void* key;
        char* value;
    } SocketStringKV;

    SocketStringKV registeredArgtypes[64];
    pthread_mutex_t registeredArgtypesMutex = PTHREAD_MUTEX_INITIALIZER;

    SocketStringKV functions[64];
    pthread_mutex_t functionsMutex = PTHREAD_MUTEX_INITIALIZER;
}
$cc proc getFunctions {void* socket} char* {
    pthread_mutex_lock(&functionsMutex);
    for (int i = 0; i < 64; i++) {
        if (functions[i].key == socket) {
            char* result = functions[i].value;
            pthread_mutex_unlock(&functionsMutex);
            return result ? result : "";
        }
    }
    pthread_mutex_unlock(&functionsMutex);
    return "";
}
$cc proc getRegisteredArgtypes {void* socket} char* {
    pthread_mutex_lock(&registeredArgtypesMutex);
    for (int i = 0; i < 64; i++) {
        if (registeredArgtypes[i].key == socket) {
            char* result = registeredArgtypes[i].value;
            pthread_mutex_unlock(&registeredArgtypesMutex);
            return result ? result : "";
        }
    }
    pthread_mutex_unlock(&registeredArgtypesMutex);
    return "";
}
$cc proc setFunctions {void* socket char* value} void {
    pthread_mutex_lock(&functionsMutex);

    // Find or create entry for this socket
    int slot = -1;
    for (int i = 0; i < 64; i++) {
        if (functions[i].key == socket) {
            slot = i;
            break;
        }
        if (functions[i].key == NULL && slot == -1) {
            slot = i;
        }
    }

    if (slot == -1) {
        pthread_mutex_unlock(&functionsMutex);
        FOLK_ERROR("setFunctions: No free slots\n");
    }

    // Free old value and store new one
    if (functions[slot].value) {
        free(functions[slot].value);
    }
    functions[slot].key = socket;
    functions[slot].value = strdup(value);

    pthread_mutex_unlock(&functionsMutex);
}
$cc proc setRegisteredArgtypes {void* socket char* value} void {
    pthread_mutex_lock(&registeredArgtypesMutex);

    // Find or create entry for this socket
    int slot = -1;
    for (int i = 0; i < 64; i++) {
        if (registeredArgtypes[i].key == socket) {
            slot = i;
            break;
        }
        if (registeredArgtypes[i].key == NULL && slot == -1) {
            slot = i;
        }
    }

    if (slot == -1) {
        pthread_mutex_unlock(&registeredArgtypesMutex);
        FOLK_ERROR("setRegisteredArgtypes: No free slots\n");
    }

    // Free old value and store new one
    if (registeredArgtypes[slot].value) {
        free(registeredArgtypes[slot].value);
    }
    registeredArgtypes[slot].key = socket;
    registeredArgtypes[slot].value = strdup(value);

    pthread_mutex_unlock(&registeredArgtypesMutex);
}

set zmq [$cc compile]

proc Uvx args {zmq UVX} {
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
                    deserialized = registered_argtypes[argtype](socket)
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

    # Return a library that runs internal state through the Folk db so
    # it can be called from any thread.
    return [library create uvx {zmq socket} {
proc getFunctions {} {
    variable zmq; variable socket
    return [$zmq getFunctions $socket] }
proc getRegisteredArgtypes {} {
    variable zmq; variable socket
    return [$zmq getRegisteredArgtypes $socket]
}
proc registerFunction {fnName fnInfo} {
    variable zmq; variable socket
    set functions [$zmq getFunctions $socket]
    dict set functions $fnName $fnInfo
    $zmq setFunctions $socket $functions
}
proc registerArgtype {typeName serializer} {
    variable zmq; variable socket
    set argtypes [$zmq getRegisteredArgtypes $socket]
    dict set argtypes $typeName $serializer
    $zmq setRegisteredArgtypes $socket $argtypes
}

proc unknown {fnName args} {
    variable zmq; variable socket

    # Send function name first
    $zmq zmqSendMore $socket $fnName

    # Check if this function has registered types
    set functions [getFunctions]
    set registeredArgtypes [getRegisteredArgtypes]
    if {[dict exists $functions $fnName]} {
        set fnInfo [dict get $functions $fnName]
        set argTypes [dict get $fnInfo argTypes]

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
proc exec {code} { return [unknown "exec" [undent $code]] }
proc eval {code} { return [unknown "eval" $code] }

proc argtype {typeName serializer deserializer} {
    # Store the Tcl serializer:
    registerArgtype $typeName $serializer
    # Store the Python deserializer:
    __register_argtype__ $typeName $deserializer
}
proc def {fnName argSpec body} {
    # Parse argument specification: {Type1 name1 Type2 name2 ...}
    set argNames {}
    set argTypes {}
    foreach {argType argName} $argSpec {
        lappend argNames $argName
        lappend argTypes $argType
    }

    # Store function metadata
    registerFunction $fnName [dict create \
        argNames $argNames \
        argTypes $argTypes]

    # Register function signature with Python
    __register_function__ $fnName {*}$argTypes

    # Strip common leading whitespace and add function body indentation
    set dedented [undent $body]
    set indentedBody [indent $dedented "    "]
    # If body is empty, add pass statement
    if {[string trim $indentedBody] eq ""} {
        set indentedBody "    pass\n"
    }
    exec "def $fnName\([join $argNames ", "]):
$indentedBody"
}
    }]
}
