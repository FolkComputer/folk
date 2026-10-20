set UVX "$env::HOME/.local/bin/uvx"
if {![file exists $UVX]} { set UVX "uvx" }

set cc [dict link $C {}]
cc::include <sys/socket.h>
cc::include <sys/un.h>
cc::include <unistd.h>
cc::include <pthread.h>
cc::include <string.h>
cc::include <stdlib.h>

cc::proc sockConnect {char* path} int {
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
    Zicl_SetResultString(interp, "sockConnect: failed to connect", -1);
    return -1;
}

# Returns this thread's connection to `endpoint`, dialing on first use.
cc::proc sockForEndpoint {char* endpoint} int {
    for (int i = 0; i < 16; i++) {
        if (threadSockets[i].key[0] != '\0' &&
            strcmp(threadSockets[i].key, endpoint) == 0) {
            return threadSockets[i].fd;
        }
    }

    int slot = -1;
    for (int i = 0; i < 16; i++) {
        if (threadSockets[i].key[0] == '\0') { slot = i; break; }
    }
    if (slot == -1) { FOLK_ERROR("sockForEndpoint: no free slots\n"); }

    int fd = sockConnect(endpoint);
    if (fd < 0) { FOLK_ERROR("sockForEndpoint: failed to connect to %s\n", endpoint); }

    strncpy(threadSockets[slot].key, endpoint, ENDPOINT_MAX - 1);
    threadSockets[slot].key[ENDPOINT_MAX - 1] = '\0';
    threadSockets[slot].fd = fd;
    return fd;
}

cc::proc sockSendStr {int fd char* data} void {
    uint32_t len = (uint32_t)strlen(data);
    // HACK: should check these.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wunused-result"
    write(fd, &len, 4);
    if (len > 0) write(fd, data, len);
#pragma GCC diagnostic pop
}

cc::proc sockRecvMulti {int fd} Zicl_Value {
    Zicl_List* result = ziclNewList(NULL, 0);
    while (1) {
        uint32_t len = 0;
        int got = 0;
        while (got < 4) {
            int n = read(fd, ((char*)&len) + got, 4 - got);
            if (n <= 0) return Zicl_BoxList(result);
            got += n;
        }
        if (len == 0) break;
        char *buf = (char*)malloc(len + 1);
        got = 0;
        while ((uint32_t)got < len) {
            int n = read(fd, buf + got, len - got);
            if (n <= 0) { free(buf); return Zicl_BoxList(result); }
            got += n;
        }
        buf[len] = '\0';
        ziclListAppend(result, ziclNewString(buf, len));
        free(buf);
    }
    return Zicl_BoxList(result);
}

# These need to be maintained in C so that they can be written and
# read from multiple threads (any thread may call into the Python
# module at any time).
cc::addcode {
    // This C module is global, so we need to maintain a separate
    // functions/registeredArgtypes per uvx (per endpoint).

    #define ENDPOINT_MAX 256

    typedef struct EndpointKV {
        char key[ENDPOINT_MAX];
        Zicl_Value value;
    } EndpointKV;

    EndpointKV registeredArgtypes[64];
    pthread_mutex_t registeredArgtypesMutex = PTHREAD_MUTEX_INITIALIZER;

    EndpointKV functions[64];
    pthread_mutex_t functionsMutex = PTHREAD_MUTEX_INITIALIZER;

    // One connection per (thread, endpoint). The wire protocol is
    // length-prefixed request/response, so two Folk workers sharing an fd
    // would interleave frames and desync it. Thread-local because a Folk
    // value is shared across worker threads, so the fd cannot ride along in
    // the library dict the way it did under Jim's per-thread namespaces.
    typedef struct EndpointSocket {
        char key[ENDPOINT_MAX];
        int fd;
    } EndpointSocket;
    _Thread_local EndpointSocket threadSockets[16];
}
cc::proc getFunctions {char* endpoint} Zicl_Value {
    pthread_mutex_lock(&functionsMutex);
    for (int i = 0; i < 64; i++) {
        if (functions[i].key[0] != '\0' && strcmp(functions[i].key, endpoint) == 0) {
            Zicl_Value result = Zicl_Ref(functions[i].value);
            pthread_mutex_unlock(&functionsMutex);
            return result;
        }
    }
    pthread_mutex_unlock(&functionsMutex);
    return Zicl_BoxDict(ziclNewDict(NULL, 0));
}
cc::proc getRegisteredArgtypes {char* endpoint} Zicl_Value {
    pthread_mutex_lock(&registeredArgtypesMutex);
    for (int i = 0; i < 64; i++) {
        if (registeredArgtypes[i].key[0] != '\0' && strcmp(registeredArgtypes[i].key, endpoint) == 0) {
            Zicl_Value result = Zicl_Ref(registeredArgtypes[i].value);
            pthread_mutex_unlock(&registeredArgtypesMutex);
            return result;
        }
    }
    pthread_mutex_unlock(&registeredArgtypesMutex);
    return Zicl_BoxDict(ziclNewDict(NULL, 0));
}
cc::proc setFunctions {char* endpoint Zicl_Value value} void {
    Zicl_MakeCrossthread(value);
    pthread_mutex_lock(&functionsMutex);

    int slot = -1;
    for (int i = 0; i < 64; i++) {
        if (functions[i].key[0] != '\0' && strcmp(functions[i].key, endpoint) == 0) {
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

    if (functions[slot].key[0] != '\0') {
        Zicl_DropRef(functions[slot].value);
    }
    strncpy(functions[slot].key, endpoint, ENDPOINT_MAX - 1);
    functions[slot].key[ENDPOINT_MAX - 1] = '\0';
    functions[slot].value = Zicl_Ref(value);

    pthread_mutex_unlock(&functionsMutex);
}
cc::proc setRegisteredArgtypes {char* endpoint Zicl_Value value} void {
    Zicl_MakeCrossthread(value);
    pthread_mutex_lock(&registeredArgtypesMutex);

    int slot = -1;
    for (int i = 0; i < 64; i++) {
        if (registeredArgtypes[i].key[0] != '\0' && strcmp(registeredArgtypes[i].key, endpoint) == 0) {
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

    if (registeredArgtypes[slot].key[0] != '\0') {
        Zicl_DropRef(registeredArgtypes[slot].value);
    }
    strncpy(registeredArgtypes[slot].key, endpoint, ENDPOINT_MAX - 1);
    registeredArgtypes[slot].key[ENDPOINT_MAX - 1] = '\0';
    registeredArgtypes[slot].value = Zicl_Ref(value);

    pthread_mutex_unlock(&registeredArgtypesMutex);
}
cc::proc cleanupEndpoint {char* endpoint} void {
    pthread_mutex_lock(&functionsMutex);
    for (int i = 0; i < 64; i++) {
        if (functions[i].key[0] != '\0' && strcmp(functions[i].key, endpoint) == 0) {
            functions[i].key[0] = '\0';
            Zicl_DropRef(functions[i].value);
            break;
        }
    }
    pthread_mutex_unlock(&functionsMutex);

    pthread_mutex_lock(&registeredArgtypesMutex);
    for (int i = 0; i < 64; i++) {
        if (registeredArgtypes[i].key[0] != '\0' && strcmp(registeredArgtypes[i].key, endpoint) == 0) {
            registeredArgtypes[i].key[0] = '\0';
            Zicl_DropRef(registeredArgtypes[i].value);
            break;
        }
    }
    pthread_mutex_unlock(&registeredArgtypesMutex);
}

set impl [cc::compile]

fn UvxCleanup {pid endpoint} {
    # `uvx` may keep the real Python worker as a child process. Kill children
    # first, then the wrapper. Both commands are best-effort because the worker
    # may already have exited by the time the match is retracted.
    catch {exec {pkill -TERM -P $pid}}
    catch {exec {kill $pid}}
    catch {impl::cleanupEndpoint $endpoint}
    catch {file {delete -force $endpoint}}

    after 1000 [list apply [fn {pid} {
        catch {exec {pkill -KILL -P $pid}}
        catch {exec {kill SIGKILL $pid}}
    }] $pid]
}

fn Uvx args {
    set endpoint "/tmp/uvx-[clock milliseconds]-[expr {int(rand() * 100000)}].sock"
    set folkPid [pid]

    set harnessCode [subst -nocommands -nobackslashes {
import sys
import os
import socket
import struct
import json
import threading
import time

folk_pid = $folkPid
uvx_parent_pid = os.getppid()

def process_is_zombie(pid):
    try:
        with open(f"/proc/{pid}/stat") as f:
            return f.read().split()[2] == "Z"
    except OSError:
        return False

def exit_when_parent_is_gone():
    while True:
        time.sleep(1)
        if os.getppid() != uvx_parent_pid:
            os._exit(0)
        try:
            os.kill(folk_pid, 0)
        except OSError:
            os._exit(0)
        if process_is_zombie(folk_pid):
            os._exit(0)

threading.Thread(target=exit_when_parent_is_gone, daemon=True).start()

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
            if isinstance(result, (bytes, bytearray)):
                send_frame(conn, b"okb")
                send_frame(conn, result)
            else:
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
    catch { On unmatch { UvxCleanup $pid $endpoint } } res

    # Return a library that runs internal state through the Folk db so
    # it can be called from any thread.
    # The library is a plain dict of closures. Everything below is defined as
    # an ordinary local first and only assembled into the dict at the end, so
    # each one captures this frame and can call the ones above it by name.
    # Nothing here may be named `exec` or `eval`: this frame calls both.

    fn pyGetFunctions {} { return [impl::getFunctions $endpoint] }
    fn pyGetRegisteredArgtypes {} { return [impl::getRegisteredArgtypes $endpoint] }

    fn pyRegisterFunction {fnName fnInfo} {
        set functions [impl::getFunctions $endpoint]
        dict set functions $fnName $fnInfo
        impl::setFunctions $endpoint $functions
    }
    fn pyRegisterArgtype {typeName serializer} {
        set argtypes [impl::getRegisteredArgtypes $endpoint]
        dict set argtypes $typeName $serializer
        impl::setRegisteredArgtypes $endpoint $argtypes
    }

    fn pyCall {fnName args} {
        # Dialed per thread, since a Folk value is shared across workers and a
        # shared fd would interleave frames on this request/response protocol.
        set socket [impl::sockForEndpoint $endpoint]

        # Send function name first
        impl::sockSendStr $socket $fnName

        # Check if this function has registered types
        set functions [pyGetFunctions]
        set registeredArgtypes [pyGetRegisteredArgtypes]
        if {[dict exists $functions $fnName]} {
            set fnInfo [dict get $functions $fnName]
            set argTypes [dict get $fnInfo argTypes]

            # Send each argument according to its type
            foreach schema $argTypes arg $args {
                # Check if this is a custom argtype
                if {[dict exists $registeredArgtypes $schema]} {
                    # A closure rather than a code string: zicl's [apply] has no
                    # `{argList body}` lambda form. It round-trips through the C
                    # slot as its string, scope hash and all.
                    apply [dict get $registeredArgtypes $schema] $socket $arg
                } else {
                    # Use JSON encoding
                    set encoded [json::encode $arg $schema]
                    impl::sockSendStr $socket $encoded
                }
            }

        } else {
            # No type info, send args as strings
            foreach arg $args { impl::sockSendStr $socket $arg }
        }

        # Send terminator.
        impl::sockSendStr $socket ""

        set response [impl::sockRecvMulti $socket]
        if {[llength $response] == 0} {
            error "Python worker at $endpoint closed the connection"
        }

        lassign $response status value
        if {$status eq "error"} { error $value }
        if {$status eq "okb"} { return $value }
        if {$status ne "ok"} {
            error "Python worker at $endpoint returned invalid response: $response"
        }
        return [json::decode $value]
    }

    fn pyExec {code} {
        lassign [info source $code] file line
        if {$file eq ""} { set file "<unknown>"; set line 1 }
        return [pyCall "__exec__" [textutil::adjust::undent $code] $file $line]
    }
    fn pyEval {code} { return [pyCall "eval" $code] }

    # `serializer` is a closure taking {socket arg}; `deserializer` is Python
    # source that reads from `socket` and returns the value.
    fn pyArgtype {typeName serializer deserializer} {
        # Store the Tcl serializer:
        pyRegisterArgtype $typeName $serializer
        # Store the Python deserializer:
        pyCall __register_argtype__ $typeName $deserializer
    }

    # A method, so that the closure it defines lands in the caller's own copy
    # of the library dict: `$py::def foo` writes `foo` back into `$py`.
    method pyDef {self fnName argSpec body} {
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
        pyRegisterFunction $fnName [dict create \
            argNames $argNames \
            argTypes $argTypes]

        # Register function signature with Python
        pyCall __register_function__ $fnName {*}$argTypes

        # Strip common leading whitespace and add function body indentation
        set dedented [textutil::adjust::undent $body]
        set indentedBody [textutil::adjust::indent $dedented "    "]
        # If body is empty, add pass statement
        if {[string trim $indentedBody] eq ""} {
            set indentedBody "    pass\n"
        }
        # line - 1 because the def header line takes the place of the opening brace
        pyCall "__exec__" "def $fnName\([join $argNames ", "]):\n$indentedBody" $file [expr {$line - 1}]

        # Bind it as a real key, so `$py::$fnName` is an ordinary dict lookup
        # rather than something an [unknown] handler has to intercept.
        dict set self $fnName [fn args { return [pyCall $fnName {*}$args] }]
    }

    return [dict create \
                call $pyCall \
                exec $pyExec \
                eval $pyEval \
                argtype $pyArgtype \
                def $pyDef \
                getFunctions $pyGetFunctions \
                getRegisteredArgtypes $pyGetRegisteredArgtypes]
}
