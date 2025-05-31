set cc [C]
$cc include <errno.h>
$cc include <sys/socket.h>
$cc include <string.h>
$cc include <unistd.h>
$cc include <fcntl.h>

$cc include <wslay/wslay.h>

$cc code {
    typedef struct WsSession {
        int fd;
        Jim_Obj* onMsgRecv;
    } WsSession;

    static ssize_t recv_callback(wslay_event_context_ptr ctx,
                                 uint8_t* buf, size_t len, int flags,
                                 void* user_data) {
        WsSession* session = (WsSession*) user_data;

        ssize_t r;
        while((r = recv(session->fd, buf, len, 0)) == -1 && errno == EINTR);
        if(r == -1) {
            if(errno == EAGAIN || errno == EWOULDBLOCK) {
                wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
            } else {
                wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
            }
        } else if(r == 0) {
            /* Unexpected EOF is also treated as an error */
            wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
            r = -1;
        }
        return r;
    }
    static ssize_t send_callback(wslay_event_context_ptr ctx,
                                 const uint8_t* data, size_t len, int flags,
                                 void* user_data) {
        WsSession* session = (WsSession*) user_data;

        ssize_t r;
        int sflags = 0;
#ifdef MSG_MORE
        if(flags & WSLAY_MSG_MORE) {
            sflags |= MSG_MORE;
        }
#endif // MSG_MORE
        while((r = send(session->fd, data, len, sflags)) == -1 && errno == EINTR);
        if(r == -1) {
            if(errno == EAGAIN || errno == EWOULDBLOCK) {
                wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
            } else {
                wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
            }
        }
        return r;
    }
    static void on_msg_recv_callback(wslay_event_context_ptr ctx,
                                     const struct wslay_event_on_msg_recv_arg* arg,
                                     void* user_data) {
        WsSession* session = (WsSession*) user_data;
        if (!wslay_is_ctrl_frame(arg->opcode)) {
            Jim_Obj* msgObj = Jim_NewStringObj(interp, arg->msg, arg->msg_length);
            if (Jim_EvalObjPrefix(interp, session->onMsgRecv,
                                  1, &msgObj) == JIM_ERR) {
                Jim_MakeErrorMessage(interp);
                fprintf(stderr, "ws.tcl: on_msg_recv_callback: Error: (%s)\n",
                        Jim_GetString(Jim_GetResult(interp), NULL));
            }
        }
    }

    struct wslay_event_callbacks callbacks = {
        .recv_callback = recv_callback,
        .send_callback = send_callback,
        .genmask_callback = NULL,
        .on_frame_recv_start_callback = NULL,
        .on_frame_recv_chunk_callback = NULL,
        .on_frame_recv_end_callback = NULL,
        .on_msg_recv_callback = on_msg_recv_callback
    };

    int wsPipeRead;
    int wsPipeWrite;
}
$cc typedef {struct wslay_event_context*} wslay_event_context_ptr
$cc proc init {Jim_Obj* pipeReadObj Jim_Obj* pipeWriteObj} void {
    wsPipeRead = Jim_AioFilehandle(interp, pipeReadObj);
    if (wsPipeRead < 0) { FOLK_ERROR("ws: wsPipeRead is invalid\n"); }

    int flags = fcntl(wsPipeRead, F_GETFL, 0);
    fcntl(wsPipeRead, F_SETFL, flags | O_NONBLOCK);

    wsPipeWrite = Jim_AioFilehandle(interp, pipeWriteObj);
    if (wsPipeWrite < 0) { FOLK_ERROR("ws: wsPipeWrite is invalid\n"); }
}
$cc proc wsNew {Jim_Obj* chan Jim_Obj* onMsgRecv} wslay_event_context_ptr {
    // Convert chan to an int fd:
    int fd = Jim_AioFilehandle(interp, chan);
    if (fd < 0) {
        FOLK_ERROR("web: Unable to open channel as file\n");
    }

    WsSession* session = (WsSession*) malloc(sizeof(WsSession));
    session->fd = fd;
    session->onMsgRecv = onMsgRecv;
    Jim_IncrRefCount(onMsgRecv);

    wslay_event_context_ptr ctx;
    wslay_event_context_server_init(&ctx, &callbacks, (void*) session);
    fprintf(stderr, "wsInit\n");
    return ctx;
}

$cc proc wsReadable {wslay_event_context_ptr ctx} void {
    int r = wslay_event_recv(ctx);
    if (r != 0) {
        fprintf(stderr, "ws: wslay_event_recv: %d\n", r);
    }
}
$cc proc wsWritable {wslay_event_context_ptr ctx} void {
    int r = wslay_event_send(ctx);
    if (r != 0) {
        fprintf(stderr, "ws: wslay_event_send: %d\n", r);
    }
}
$cc proc wsWantRead {wslay_event_context_ptr ctx} bool {
    return wslay_event_want_read(ctx);
}
$cc proc wsWantWrite {wslay_event_context_ptr ctx} bool {
    return wslay_event_want_write(ctx);
}

# This function is designed to be callable from any thread, so
# arbitrary When bodies can emit data onto the WebSocket (since they
# may run on any thread).
$cc proc wsEmitMsg {wslay_event_context_ptr ctx char* data} void {
    uint8_t pipedata[sizeof(ctx) + sizeof(data)];
    memcpy(&pipedata[0], &ctx, sizeof(ctx));
    char* datadup = strdup(data);
    // The datadup string will be freed at the web thread on receipt.
    memcpy(&pipedata[sizeof(ctx)], &datadup, sizeof(datadup));
    if (write(wsPipeWrite, pipedata, sizeof(pipedata)) != sizeof(pipedata)) {
        FOLK_ERROR("ws: wsEmitMsg: write failed\n");
    }
}

# This function runs on the web thread.
$cc proc wsPipeReadMsg {} wslay_event_context_ptr {
    uint8_t pipedata[sizeof(wslay_event_context_ptr) + sizeof(char*)];
    if (read(wsPipeRead, pipedata, sizeof(pipedata)) == sizeof(pipedata)) {
        wslay_event_context_ptr ctx; memcpy(&ctx, &pipedata[0], sizeof(ctx));
        char* data; memcpy(&data, &pipedata[sizeof(ctx)], sizeof(data));

        struct wslay_event_msg msg = {
            .opcode = WSLAY_TEXT_FRAME,
            .msg = data,
            .msg_length = strlen(data)
        };
        wslay_event_queue_msg(ctx, &msg);

        free(data);
        return ctx;
    }
    return NULL;
}

$cc proc wsDestroy {wslay_event_context_ptr ctx} void {
    // TODO: free the WsSession
    wslay_event_context_free(ctx);
}
$cc endcflags -lwslay

set wsLib [$cc compile]
# This pipe is used so that other threads can queue up messages to
# send out through WebSockets.
lassign [pipe] wsPipeRead wsPipeWrite

$wsLib init $wsPipeRead $wsPipeWrite

package require base64

set cc [C]
$cc include <string.h>
$cc include <openssl/sha.h>
$cc proc sha1 {char* d} Jim_Obj* {
    unsigned char md[20];
    SHA1(d, strlen(d), md);
    return Jim_NewStringObj(interp, md, 20);
}
$cc endcflags -lssl
set sha1Lib [$cc compile]

class WsConnection {
    chan {}
    ctx {}

    wsLib {}
}
WsConnection method onChanReadable {} {
    $wsLib wsReadable $ctx
    $self updateChanReadableWritable
}
WsConnection method onChanWritable {} {
    $wsLib wsWritable $ctx
    $self updateChanReadableWritable
}
WsConnection method updateChanReadableWritable {} {
    if {[$wsLib wsWantRead $ctx]} {
        $chan readable [list $self onChanReadable]
    } else {
        $chan readable {}
    }
    if {[$wsLib wsWantWrite $ctx]} {
        $chan writable [list $self onChanWritable]
    } else {
        $chan writable {}
    }
}

WsConnection method onMsgRecv {msg} {
    # puts stderr "onMsgRecv ($msg)"
    eval $msg
}

$wsPipeRead readable [lambda {} {wsLib} {
    try {
        while true {
            set ctx [$wsLib wsPipeReadMsg]
            set conn [dict get $::wsConnections $ctx]
            $conn updateChanReadableWritable
        }
    } on error e {}
}]

set ::wsConnections [dict create]

# This class method creates a new WsConnection from an active HTTP
# channel and key from /ws upgrade request header.
proc {WsConnection upgrade} {chan clientKey} {wsLib sha1Lib} {
    set acceptKeyRaw "${clientKey}258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    set acceptKey [binary encode base64 [$sha1Lib sha1 $acceptKeyRaw]]

    puts -nonewline $chan \
        "HTTP/1.1 101 Switching Protocols\r
Upgrade: websocket\r
Connection: Upgrade\r
Sec-WebSocket-Accept: $acceptKey\r
\r
"
    $chan ndelay 1

    set conn [WsConnection new \
                  [list chan $chan ctx {} wsLib $wsLib]]
    set ctx [$wsLib wsNew $chan [lambda {msg} {conn} {
        $conn onMsgRecv $msg
    }]]
    $conn eval [list set ctx $ctx]

    $conn updateChanReadableWritable
    dict set ::wsConnections $ctx $conn
    return $conn
}
