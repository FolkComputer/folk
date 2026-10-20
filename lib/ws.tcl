# WebSocket RFC 6455 protocol codec and connection helpers.

set cc [dict link $C {}]
cc::include <string.h>
cc::include <stdlib.h>
cc::include <stdint.h>
cc::include <stdbool.h>

# Encode a WebSocket frame (server to client: unmasked).
# Opcode: 1 = text, 2 = binary, 8 = close, 9 = ping, 10 = pong.
cc::proc wsEncodeFrame {int opcode Zicl_Shimmerable* payload} Zicl_Value {
    int len = 0;
    const char* data = Zicl_ShimGetString(payload, &len);
    uint8_t header[10];
    int headerLen = 0;
    header[0] = (uint8_t)(0x80 | (opcode & 0x0f));
    if (len < 126) {
        header[1] = (uint8_t)len;
        headerLen = 2;
    } else if (len <= 65535) {
        header[1] = 126;
        header[2] = (uint8_t)((len >> 8) & 0xff);
        header[3] = (uint8_t)(len & 0xff);
        headerLen = 4;
    } else {
        header[1] = 127;
        uint64_t ulen = (uint64_t)len;
        for (int i = 0; i < 8; i++) {
            header[2 + i] = (uint8_t)((ulen >> ((7 - i) * 8)) & 0xff);
        }
        headerLen = 10;
    }

    char* buf = (char*) malloc(headerLen + len);
    memcpy(buf, header, headerLen);
    if (len > 0) {
        memcpy(buf + headerLen, data, len);
    }
    Zicl_Value result = ziclNewString(buf, headerLen + len);
    free(buf);
    return result;
}

# Unmask WebSocket payload from client.
cc::proc wsUnmask {Zicl_Shimmerable* payload Zicl_Shimmerable* maskKey} Zicl_Value {
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
    Zicl_Value result = ziclNewString(out, payloadLen);
    free(out);
    return result;
}

# Parse 2-byte WebSocket frame header into a dict.
cc::proc wsParseHeader {Zicl_Shimmerable* header2Bytes} Zicl_Value {
    int len = 0;
    const unsigned char* h = (const unsigned char*) Zicl_ShimGetString(header2Bytes, &len);
    if (len < 2) {
        FOLK_ERROR("wsParseHeader: expected 2 bytes\n");
    }
    int fin = (h[0] & 0x80) ? 1 : 0;
    int opcode = h[0] & 0x0f;
    int masked = (h[1] & 0x80) ? 1 : 0;
    int payloadLen = h[1] & 0x7f;

    Zicl_Value pairs[8];
    pairs[0] = ziclNewString("fin", 3);
    pairs[1] = Zicl_NewBool(fin != 0);
    pairs[2] = ziclNewString("opcode", 6);
    pairs[3] = Zicl_NewLong(opcode);
    pairs[4] = ziclNewString("masked", 6);
    pairs[5] = Zicl_NewBool(masked != 0);
    pairs[6] = ziclNewString("length", 6);
    pairs[7] = Zicl_NewLong(payloadLen);
    return Zicl_BoxDict(ziclNewDict(pairs, 8));
}

# Parse 16-bit extended payload length.
cc::proc wsParseLength16 {Zicl_Shimmerable* bytes2} int {
    int len = 0;
    const unsigned char* b = (const unsigned char*) Zicl_ShimGetString(bytes2, &len);
    if (len < 2) {
        FOLK_ERROR("wsParseLength16: expected 2 bytes\n");
    }
    return (int)((b[0] << 8) | b[1]);
}

# Parse 64-bit extended payload length.
cc::proc wsParseLength64 {Zicl_Shimmerable* bytes8} uint64_t {
    int len = 0;
    const unsigned char* b = (const unsigned char*) Zicl_ShimGetString(bytes8, &len);
    if (len < 8) {
        FOLK_ERROR("wsParseLength64: expected 8 bytes\n");
    }
    uint64_t res = 0;
    for (int i = 0; i < 8; i++) {
        res = (res << 8) | (uint64_t)b[i];
    }
    return res;
}

set wsCodecLib [cc::compile]

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
        set header [wsCodecLib::wsParseHeader $hBytes]
        set opcode [dict get $header opcode]
        set length [dict get $header length]
        set masked [dict get $header masked]

        if {$length == 126} {
            set lBytes [wsReadExact $chan 2]
            set length [wsCodecLib::wsParseLength16 $lBytes]
        } elseif {$length == 127} {
            set lBytes [wsReadExact $chan 8]
            set length [wsCodecLib::wsParseLength64 $lBytes]
        }

        set maskKey ""
        if {$masked} {
            set maskKey [wsReadExact $chan 4]
        }

        set payload ""
        if {$length > 0} {
            set rawPayload [wsReadExact $chan $length]
            if {$masked} {
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
                    stream write $chan [wsCodecLib::wsEncodeFrame 8 ""]
                } on error e {}
                return [dict create opcode close payload ""]
            }
            9 {
                # Ping frame. Reply with Pong.
                try {
                    stream write $chan [wsCodecLib::wsEncodeFrame 10 $payload]
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
    set frame [wsCodecLib::wsEncodeFrame 1 $text]
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


