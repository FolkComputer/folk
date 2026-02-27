set UVX "$::env(HOME)/.local/bin/uvx"
if {![file exists $UVX]} { set UVX "uvx" }

set cc [C]
$cc include <sys/socket.h>
$cc include <sys/un.h>
$cc include <unistd.h>
$cc include <pthread.h>
$cc include <string.h>
$cc include <stdlib.h>

$cc proc sockConnect {char* path} int {
    for (int i = 0; i < 200; i++) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) { usleep(1000000); continue; }
        struct sockaddr_un addr;
        memset(&addr, 0, sizeof(addr));
        addr.sun_family = AF_UNIX;
        strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);
        if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
            return fd;
        }
        close(fd);
        usleep(1000000);
    }
    Jim_SetResultString(interp, "sockConnect: failed to connect", -1);
    return -1;
}

$cc proc sockSendStr {int fd char* data} void {
    uint32_t len = (uint32_t)strlen(data);
    write(fd, &len, 4);
    if (len > 0) write(fd, data, len);
}

$cc proc sockRecvMulti {int fd} Jim_Obj* {
    Jim_Obj *result = Jim_NewListObj(interp, NULL, 0);
    while (1) {
        uint32_t len = 0;
        int got = 0;
        while (got < 4) {
            int n = read(fd, ((char*)&len) + got, 4 - got);
            if (n <= 0) return result;
            got += n;
        }
        if (len == 0) break;
        char *buf = (char*)malloc(len + 1);
        got = 0;
        while ((uint32_t)got < len) {
            int n = read(fd, buf + got, len - got);
            if (n <= 0) { free(buf); return result; }
            got += n;
        }
        buf[len] = '\0';
        Jim_ListAppendElement(interp, result, Jim_NewStringObj(interp, buf, len));
        free(buf);
    }
    return result;
}

# These need to be maintained in C so that they can be written and
# read from multiple threads (any thread may call into the Python
# module at any time).
$cc code {
    // This C module is global, so we need to maintain a separate
    // functions/registeredArgtypes per uvx (per endpoint).

    #define ENDPOINT_MAX 256

    typedef struct EndpointStringKV {
        char key[ENDPOINT_MAX];
        char* value;
    } EndpointStringKV;

    EndpointStringKV registeredArgtypes[64];
    pthread_mutex_t registeredArgtypesMutex = PTHREAD_MUTEX_INITIALIZER;

    EndpointStringKV functions[64];
    pthread_mutex_t functionsMutex = PTHREAD_MUTEX_INITIALIZER;
}
$cc proc getFunctions {char* endpoint} char* {
    pthread_mutex_lock(&functionsMutex);
    for (int i = 0; i < 64; i++) {
        if (strcmp(functions[i].key, endpoint) == 0) {
            char* result = functions[i].value;
            pthread_mutex_unlock(&functionsMutex);
            return result ? result : "";
        }
    }
    pthread_mutex_unlock(&functionsMutex);
    return "";
}
$cc proc getRegisteredArgtypes {char* endpoint} char* {
    pthread_mutex_lock(&registeredArgtypesMutex);
    for (int i = 0; i < 64; i++) {
        if (strcmp(registeredArgtypes[i].key, endpoint) == 0) {
            char* result = registeredArgtypes[i].value;
            pthread_mutex_unlock(&registeredArgtypesMutex);
            return result ? result : "";
        }
    }
    pthread_mutex_unlock(&registeredArgtypesMutex);
    return "";
}
$cc proc setFunctions {char* endpoint char* value} void {
    pthread_mutex_lock(&functionsMutex);

    int slot = -1;
    for (int i = 0; i < 64; i++) {
        if (strcmp(functions[i].key, endpoint) == 0) {
            slot = i;
            break;
        }
        if (functions[i].key[0] == '\0' && slot == -1) {
            slot = i;
        }
    }

    if (slot == -1) {
        pthread_mutex_unlock(&functionsMutex);
        FOLK_ERROR("setFunctions: No free slots\n");
    }

    if (functions[slot].value) {
        free(functions[slot].value);
    }
    strncpy(functions[slot].key, endpoint, ENDPOINT_MAX - 1);
    functions[slot].key[ENDPOINT_MAX - 1] = '\0';
    functions[slot].value = strdup(value);

    pthread_mutex_unlock(&functionsMutex);
}
$cc proc setRegisteredArgtypes {char* endpoint char* value} void {
    pthread_mutex_lock(&registeredArgtypesMutex);

    int slot = -1;
    for (int i = 0; i < 64; i++) {
        if (strcmp(registeredArgtypes[i].key, endpoint) == 0) {
            slot = i;
            break;
        }
        if (registeredArgtypes[i].key[0] == '\0' && slot == -1) {
            slot = i;
        }
    }

    if (slot == -1) {
        pthread_mutex_unlock(&registeredArgtypesMutex);
        FOLK_ERROR("setRegisteredArgtypes: No free slots\n");
    }

    if (registeredArgtypes[slot].value) {
        free(registeredArgtypes[slot].value);
    }
    strncpy(registeredArgtypes[slot].key, endpoint, ENDPOINT_MAX - 1);
    registeredArgtypes[slot].key[ENDPOINT_MAX - 1] = '\0';
    registeredArgtypes[slot].value = strdup(value);

    pthread_mutex_unlock(&registeredArgtypesMutex);
}

set impl [$cc compile]

proc Uvx args {impl UVX} {
    set endpoint "/tmp/uvx-[clock milliseconds]-[expr {int(rand() * 100000)}].sock"

    set harnessCode [subst -nocommands -nobackslashes {
import sys
import socket
import struct
import json
import threading

def recv_frame(conn):
    hdr = b''
    while len(hdr) < 4:
        chunk = conn.recv(4 - len(hdr))
        if not chunk:
            raise ConnectionError("Connection closed")
        hdr += chunk
    length = struct.unpack('I', hdr)[0]
    if length == 0:
        return b''
    data = b''
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise ConnectionError("Connection closed")
        data += chunk
    return data

def send_frame(conn, data):
    if isinstance(data, str):
        data = data.encode('utf-8')
    conn.sendall(struct.pack('I', len(data)))
    if data:
        conn.sendall(data)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind('$endpoint')
server.listen(5)

# Storage for argtype deserializers and function signatures
registered_argtypes = {}
def __register_argtype__(type_name, deserializer_code):
    # Store deserializer as a function that takes conn
    # Indent the deserializer code and wrap in a function
    indented = '\n'.join('    ' + line for line in deserializer_code.split('\n'))
    func_code = f"def _deserialize_{type_name}(socket):\n{indented}"
    exec(func_code, globals())
    registered_argtypes[type_name] = globals()[f'_deserialize_{type_name}']

fn_signatures = {}
def __register_function__(fn_name, *fn_argtypes):
    fn_signatures[fn_name] = fn_argtypes

def __exec__(code, filename="<string>", lineno="1"):
    lineno = int(lineno)
    padded = '\n' * (lineno - 1) + code
    compiled = compile(padded, filename, 'exec')
    exec(compiled, globals())

def handle_conn(conn):
    while True:
        try:
            # Read function name
            fn_name = recv_frame(conn).decode('utf-8')

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
                        # Use registered deserializer, giving it direct conn access
                        deserialized = registered_argtypes[argtype](conn)
                        parsed_args.append(deserialized)
                    else:
                        # Standard JSON decode
                        arg = recv_frame(conn)
                        try:
                            parsed_args.append(json.loads(arg))
                        except (json.JSONDecodeError, ValueError):
                            parsed_args.append(arg)
                # Consume terminator
                recv_frame(conn)
            else:
                # No signature info, read until empty terminator frame
                while True:
                    arg = recv_frame(conn)
                    if len(arg) == 0:
                        break
                    parsed_args.append(arg.decode('utf-8'))

            result = func(*parsed_args)
            send_frame(conn, b"ok")
            send_frame(conn, json.dumps(result).encode('utf-8'))
            send_frame(conn, b"")

        except Exception as e:
            import traceback
            send_frame(conn, b"error")
            send_frame(conn, traceback.format_exc().encode('utf-8'))
            send_frame(conn, b"")

while True:
    conn, _ = server.accept()
    threading.Thread(target=handle_conn, args=(conn,), daemon=True).start()
}]

    set pid [exec $UVX {*}$args \
                 python -u -c $harnessCode &]
    # HACK: This is a bit of Folk poking down into the library level,
    # which is awkward.
    catch { uplevel [list On unmatch [list kill $pid]] } res

    # Return a library that runs internal state through the Folk db so
    # it can be called from any thread.
    return [library create uvx {impl endpoint} {

variable impl
variable endpoint
# We need to boot a new socket when this library is loaded onto a new
# thread. Do that now.
variable socket [$impl sockConnect $endpoint]
if {$socket < 0} { error "Uvx: failed to connect to Python at $endpoint" }

proc getFunctions {} {
    variable impl; variable endpoint
    return [$impl getFunctions $endpoint] }
proc getRegisteredArgtypes {} {
    variable impl; variable endpoint
    return [$impl getRegisteredArgtypes $endpoint]
}
proc registerFunction {fnName fnInfo} {
    variable impl; variable endpoint
    set functions [$impl getFunctions $endpoint]
    dict set functions $fnName $fnInfo
    $impl setFunctions $endpoint $functions
}
proc registerArgtype {typeName serializer} {
    variable impl; variable endpoint
    set argtypes [$impl getRegisteredArgtypes $endpoint]
    dict set argtypes $typeName $serializer
    $impl setRegisteredArgtypes $endpoint $argtypes
}

proc unknown {fnName args} {
    variable impl; variable socket
    # We need normal `unknown` to call methods on $impl, so need to
    # pass it through to ::unknown.
    if {$fnName eq $impl} {
        tailcall ::unknown $fnName {*}$args
    }

    # Send function name first
    $impl sockSendStr $socket $fnName

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
                apply [list {socket arg} $serializerCode] $socket $arg
            } else {
                # Use JSON encoding
                set encoded [json::encode $arg $schema]
                $impl sockSendStr $socket $encoded
            }
        }

    } else {
        # No type info, send args as strings
        foreach arg $args { $impl sockSendStr $socket $arg }
    }

    # Send terminator.
    $impl sockSendStr $socket ""

    set response [$impl sockRecvMulti $socket]

    lassign $response status value
    if {$status eq "error"} { error $value }
    return [json::decode $value]
}
proc exec {code} {
    lassign [info source $code] file line
    if {$file eq ""} { set file "<unknown>"; set line 1 }
    return [unknown "__exec__" [undent $code] $file $line]
}
proc eval {code} { return [unknown "eval" $code] }

proc argtype {typeName serializer deserializer} {
    # Store the Tcl serializer:
    registerArgtype $typeName $serializer
    # Store the Python deserializer:
    __register_argtype__ $typeName $deserializer
}
proc def {fnName argSpec body} {
    lassign [info source $body] file line
    if {$file eq ""} { set file "<unknown>"; set line 1 }

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
    # line - 1 because the def header line takes the place of the opening brace
    unknown "__exec__" "def $fnName\([join $argNames ", "]):\n$indentedBody" $file [::expr {$line - 1}]
}
    }]
}
