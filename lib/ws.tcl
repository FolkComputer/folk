# WebSocket RFC 6455 protocol codec and connection helpers.

set cc [dict link $C {}]
cc::include <string.h>
cc::include <stdlib.h>
cc::include <stdint.h>

# Unmask WebSocket payload from client.
cc::proc wsUnmask {Zicl_Shim* payload Zicl_Shim* maskKey} Zicl_Val {
    int payloadLen = 0;
    const char* payloadBytes = Zicl_ShimGetString(payload, &payloadLen);
    int maskLen = 0;
    const char* maskBytes = Zicl_ShimGetString(maskKey, &maskLen);
    if (maskLen < 4) {
        FOLK_ERROR("wsUnmask: mask key must be at least 4 bytes\n");
    }
    char* out = (char*) malloc(payloadLen);
    for (int i = 0; i < payloadLen; i++) {
        out[i] = payloadBytes[i] ^ maskBytes[i % 4];
    }
    Zicl_Val result = ziclNewString(out, payloadLen);
    free(out);
    return result;
}

set wsCodecLib [cc::compile]

# Encode a WebSocket frame (server to client: unmasked).
# Opcode: 1 = text, 2 = binary, 8 = close, 9 = ping, 10 = pong.
fn wsEncodeFrame {opcode payload} {
    set len [string bytelength $payload]
    if {$len < 126} {
        set hdr [binary encode {fin=u1be rsv=u3be opcode=u4be masked=u1be length=u7be} \
            [list fin 1 rsv 0 opcode $opcode masked 0 length $len]]
    } elseif {$len <= 65535} {
        set hdr [binary encode {fin=u1be rsv=u3be opcode=u4be masked=u1be length=u7be ext=u16be} \
            [list fin 1 rsv 0 opcode $opcode masked 0 length 126 ext $len]]
    } else {
        set hdr [binary encode {fin=u1be rsv=u3be opcode=u4be masked=u1be length=u7be ext=u64be} \
            [list fin 1 rsv 0 opcode $opcode masked 0 length 127 ext $len]]
    }
    return "${hdr}${payload}"
}

# Read exact number of bytes from stream, or error on EOF.
fn wsReadExact {chan n} {
    set buf ""
    while {[string bytelength $buf] < $n} {
        set remaining [expr {$n - [string bytelength $buf]}]
        set chunk [stream read $chan $remaining]
        if {[string bytelength $chunk] == 0} {
            error "ws: unexpected EOF while reading $n bytes"
        }
        append buf $chunk
    }
    return $buf
}

# Read a WebSocket message from connection.
# Returns dict: opcode ("text", "binary", "close") and payload.
fn wsReadMsg {chan} {
    while true {
        set hBytes [wsReadExact $chan 2]
        set header [binary decode {fin=u1be rsv=u3be opcode=u4be masked=u1be length=u7be} $hBytes]
        dict assign $header opcode length masked

        if {$length == 126} {
            set length [binary decode u16be [wsReadExact $chan 2]]
        } elseif {$length == 127} {
            set length [binary decode u64be [wsReadExact $chan 8]]
        }

        set maskKey ""
        if {$masked != 0} {
            set maskKey [wsReadExact $chan 4]
        }

        set payload ""
        if {$length > 0} {
            set rawPayload [wsReadExact $chan $length]
            if {$masked != 0} {
                set payload [wsCodecLib::wsUnmask $rawPayload $maskKey]
            } else {
                set payload $rawPayload
            }
        }

        switch -exact -- $opcode {
            1 {
                # Text frame.
                return [dict create opcode text payload $payload]
            }
            2 {
                # Binary frame.
                return [dict create opcode binary payload $payload]
            }
            8 {
                # Close frame. Send close response and return.
                try {
                    stream write $chan [wsEncodeFrame 8 ""]
                } on error e {}
                return [dict create opcode close payload ""]
            }
            9 {
                # Ping frame. Reply with Pong.
                try {
                    stream write $chan [wsEncodeFrame 10 $payload]
                } on error e {}
            }
            10 {
                # Pong frame. Ignore.
            }
            default {
                error "ws: unsupported opcode $opcode"
            }
        }
    }
}

# Send a text message over WebSocket connection.
fn wsSend {chan text} {
    set frame [wsEncodeFrame 1 $text]
    stream write $chan $frame
}

# Compute Sec-WebSocket-Accept handshake header value.
fn wsUpgradeHandshake {clientKey} {
    set acceptKeyRaw "${clientKey}258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    set acceptHash [codec hash sha-1 $acceptKeyRaw]
    return [codec encode base64 $acceptHash]
}

# Aliases for module usage.
set send $wsSend
set readMsg $wsReadMsg
set upgradeHandshake $wsUpgradeHandshake


