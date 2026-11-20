// hidemu.c -- emulated USB HID boot-protocol keyboard + mouse for kernels without uinput/uhid.
//
// Models two layers and writes the result of the second one to a FIFO (or any path):
//
//   1. the DEVICE: a USB HID boot keyboard (8-byte input reports: modifier bitmap, reserved,
//      6 key slots = 6-key rollover, ErrorRollOver when more than 6 keys are down) and a USB HID
//      mouse (5-byte reports: buttons, dx, dy, wheel, pan; int8 deltas, so a large move is split
//      over several reports, one per polling interval);
//   2. the KERNEL: what drivers/hid/hid-input.c + drivers/input/input.c + evdev.c turn those
//      reports into: `struct input_event` frames (EV_MSC/MSC_SCAN, EV_KEY, EV_REL, EV_SYN/
//      SYN_REPORT) and the software key autorepeat (EV_KEY value 2 after REP_DELAY=250 ms, then
//      every REP_PERIOD=33 ms, each followed by SYN_REPORT with value 1).
//
// Every report and every event is appended to a ground-truth log with wall-clock timestamps.
//
// Build:  make            (needs only libc and the kernel uapi headers)
// Usage:  hidemu [--kbd PATH] [--mouse PATH] [--log FILE] [--script FILE] [--ctl SOCKET]
//                [--seed N] [--fuzz N[:kbd|mouse|all]] [--evdev-overflow] [--quiet]
//   --kbd/--mouse PATH   where the evdev events go; a FIFO is created if PATH does not exist. The FIFO is
//                        opened read-write, so hidemu never waits for a reader and may exit before the
//                        events have been read (they stay in the FIFO as long as someone has it open).
//   --log FILE           ground truth, appended, tab-separated: TIME kbd|mouse|emu KIND ...
//                        (`cmd`, `report` = raw HID report, `event` = one input_event, `error`, `stats`)
//   --script FILE        run the commands in FILE, then exit (default: commands from stdin)
//   --ctl SOCKET         listen on a unix stream socket instead; one client at a time. Every line is
//                        answered with `ok` or `err MESSAGE` once the command has been emitted
//                        completely (so a client can simply write a line and read a line). `quit` ends
//                        hidemu. Lines are limited to 4095 bytes.
//   --evdev-overflow     behave like an evdev client buffer: never block, drop frames and send
//                        SYN_DROPPED when the reader is too slow (default: block until there is room)
// Example:
//   hidemu --kbd /tmp/kbd0 --mouse /tmp/mouse0 --log /tmp/emu.log --ctl /tmp/emu.sock &
//   python3:  s = socket.socket(socket.AF_UNIX); s.connect("/tmp/emu.sock"); f = s.makefile("rw")
//             f.write('type "hello"\n'); f.flush(); f.readline()   # -> "ok\n"
// Commands (stdin, --script or the control socket; one per line, `#` starts a comment):
//   key down|up NAME          NAME is KEY_A, a, A, ctrl, shift, enter, ... or a HID usage `u0x04`
//   tap NAME [holdms]         press + release
//   chord CTRL+SHIFT+S [holdms]
//   type "text" | type text   US layout; honours `cps`
//   cps N                     typing speed for `type` in chars/s (default 10); `hold MS` key hold
//   move DX DY [MS]           relative move, split into int8 reports (spread over MS if given)
//   button left|right|middle|side|extra down|up      click NAME [holdms] [count]
//   wheel N | hwheel N        N detents (positive = up/right, like REL_WHEEL)
//   report kbd MM RR K1 K2 K3 K4 K5 K6   raw hex report     report mouse BB DX DY WH PAN
//   rate kbd|mouse HZ         polling rate; 0 = unthrottled (burst)
//   repeat DELAYMS PERIODMS   autorepeat timing (0 0 disables), like EVIOCSREP
//   sleep MS | mark TEXT | releaseall | fuzz N [kbd|mouse|all] | seed N | stats | quit
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "keynames.h" // generated from <linux/input-event-codes.h>: static const struct {const char* name; int code;} keynames[]

// ---------------------------------------------------------------------------------------------
// HID usage (page 7) -> Linux key code: the table from drivers/hid/hid-input.c (`hid_keyboard`).
#define unk 240
static const unsigned char hid_keyboard[256] = {
      0,  0,  0,  0, 30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38,
     50, 49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44,  2,  3,
      4,  5,  6,  7,  8,  9, 10, 11, 28,  1, 14, 15, 57, 12, 13, 26,
     27, 43, 43, 39, 40, 41, 51, 52, 53, 58, 59, 60, 61, 62, 63, 64,
     65, 66, 67, 68, 87, 88, 99, 70,119,110,102,104,111,107,109,106,
    105,108,103, 69, 98, 55, 74, 78, 96, 79, 80, 81, 75, 76, 77, 71,
     72, 73, 82, 83, 86,127,116,117,183,184,185,186,187,188,189,190,
    191,192,193,194,134,138,130,132,128,129,131,137,133,135,136,113,
    115,114,unk,unk,unk,121,unk, 89, 93,124, 92, 94, 95,unk,unk,unk,
    122,123, 90, 91, 85,unk,unk,unk,unk,unk,unk,unk,111,unk,unk,unk,
    unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,
    unk,unk,unk,unk,unk,unk,179,180,unk,unk,unk,unk,unk,unk,unk,unk,
    unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,unk,
    unk,unk,unk,unk,unk,unk,unk,unk,111,unk,unk,unk,unk,unk,unk,unk,
     29, 42, 56,125, 97, 54,100,126,164,166,165,163,161,115,114,113,
    150,158,159,128,136,177,178,176,142,152,173,140,unk,unk,unk,unk
};

// ---------------------------------------------------------------------------------------------
// time, log
static int64_t monoNs(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}
static FILE* logf_ = NULL;
static bool quiet = false;
static void logLine(const char* dev, const char* fmt, ...) {
    if (!logf_) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    fprintf(logf_, "%lld.%06ld\t%s\t", (long long)tv.tv_sec, (long)tv.tv_usec, dev);
    va_list ap; va_start(ap, fmt); vfprintf(logf_, fmt, ap); va_end(ap);
    fputc('\n', logf_);
}
static const char* keyName(int code) {
    for (size_t i = 0; i < sizeof(keynames)/sizeof(keynames[0]); i++)
        if (keynames[i].code == code) return keynames[i].name;
    static char buf[16]; snprintf(buf, sizeof(buf), "KEY_%d", code); return buf;
}
static const char* relName(int code) {
    switch (code) {
    case REL_X: return "REL_X"; case REL_Y: return "REL_Y";
    case REL_WHEEL: return "REL_WHEEL"; case REL_HWHEEL: return "REL_HWHEEL";
    case REL_WHEEL_HI_RES: return "REL_WHEEL_HI_RES"; case REL_HWHEEL_HI_RES: return "REL_HWHEEL_HI_RES";
    }
    return "REL_?";
}

// ---------------------------------------------------------------------------------------------
// The "evdev client": one output path per device; one write() per frame (<= PIPE_BUF, so atomic).
typedef struct {
    const char* name; const char* path;
    int fd;
    struct input_event frame[64]; int n;
    bool overflowMode, overflowed;
    uint64_t events, frames, reports, droppedFrames;
    int64_t intervalNs, nextSlotNs; // polling interval of the device's interrupt endpoint
} Dev;

static void devOpen(Dev* d, const char* path, bool overflowMode) {
    struct stat st;
    d->path = path; d->overflowMode = overflowMode;
    if (stat(path, &st) != 0) {
        if (mkfifo(path, 0666) != 0) { perror(path); exit(1); }
        stat(path, &st);
    }
    if (S_ISFIFO(st.st_mode)) {
        // O_RDWR: never blocks waiting for a reader, never gets SIGPIPE/EPIPE when the reader
        // goes away, and keeps the FIFO "connected" so the reader never sees EOF.
        d->fd = open(path, O_RDWR | (overflowMode ? O_NONBLOCK : 0));
        if (d->fd >= 0 && overflowMode) fcntl(d->fd, F_SETPIPE_SZ, 4096); // ~170 events, like a small evdev client buffer
    } else {
        d->fd = open(path, O_WRONLY | O_APPEND);
    }
    if (d->fd < 0) { perror(path); exit(1); }
}
static void emit(Dev* d, int type, int code, int value) {
    if (d->n >= 62) return;
    struct input_event* e = &d->frame[d->n++];
    memset(e, 0, sizeof(*e));
    e->type = type; e->code = code; e->value = value;
    switch (type) {
    case EV_KEY: logLine(d->name, "event\tEV_KEY\t%s\t%d", keyName(code), value); break;
    case EV_REL: logLine(d->name, "event\tEV_REL\t%s\t%d", relName(code), value); break;
    case EV_MSC: logLine(d->name, "event\tEV_MSC\tMSC_SCAN\t0x%x", value); break;
    }
}
// input_sync(): a frame with nothing in it is not passed on (input.c: `if (dev->num_vals >= 2)`).
static void flushFrame(Dev* d, int synValue) {
    if (d->n == 0) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    struct input_event out[66]; int n = 0;
    if (d->overflowed) { // evdev: after a client buffer overrun the next packet starts with SYN_DROPPED
        memset(&out[n], 0, sizeof(out[n])); out[n].type = EV_SYN; out[n].code = SYN_DROPPED; n++;
        logLine(d->name, "event\tEV_SYN\tSYN_DROPPED\t0");
    }
    memcpy(&out[n], d->frame, d->n * sizeof(struct input_event)); n += d->n;
    memset(&out[n], 0, sizeof(out[n])); out[n].type = EV_SYN; out[n].code = SYN_REPORT; out[n].value = synValue; n++;
    for (int i = 0; i < n; i++) { out[i].input_event_sec = tv.tv_sec; out[i].input_event_usec = tv.tv_usec; } // evdev stamps the whole packet once
    d->n = 0;
    if (d->fd < 0) { logLine(d->name, "event\tEV_SYN\tSYN_REPORT\t%d\t(no output path)", synValue); return; }
    int64_t t0 = monoNs();
    ssize_t want = n * sizeof(struct input_event), got = write(d->fd, out, want);
    int64_t dt = monoNs() - t0;
    if (got == want) {
        d->events += n; d->frames++; d->overflowed = false;
        logLine(d->name, "event\tEV_SYN\tSYN_REPORT\t%d", synValue);
        if (dt > 1000000) logLine(d->name, "blocked\t%lld us (reader is slower than the device)", (long long)(dt / 1000));
    } else if (got < 0 && errno == EAGAIN && d->overflowMode) {
        d->droppedFrames++; d->overflowed = true;
        logLine(d->name, "dropped\tframe of %d events (client buffer full)", n);
    } else {
        logLine(d->name, "error\twrite: %s (wrote %zd of %zd)", strerror(errno), got, want);
        if (!quiet) fprintf(stderr, "hidemu: write %s: %s\n", d->path, strerror(errno));
    }
}

// ---------------------------------------------------------------------------------------------
// Keyboard: device state -> 8-byte boot report -> hid-input -> input core (+ autorepeat)
static Dev kbd = { .name = "kbd", .fd = -1, .intervalNs = 8000000 };   // bInterval 8 ms = 125 Hz
static Dev mouse = { .name = "mouse", .fd = -1, .intervalNs = 8000000 };
static struct {
    uint8_t mods;            // device: bit0 LCtrl 1 LShift 2 LAlt 3 LGUI 4 RCtrl 5 RShift 6 RAlt 7 RGUI
    uint8_t down[16]; int ndown; // device: pressed non-modifier usages, in press order
    uint8_t kMods, kKeys[6]; // kernel: previous value of the modifier field and of the array field
    uint8_t kKeyState[KEY_CNT / 8 + 1]; // kernel: input_dev->key bitmap
    int repeatKey; int64_t repeatAtNs; // kernel: dev->repeat_key and its timer
    int repDelayMs, repPeriodMs;
} K = { .repeatKey = -1, .repDelayMs = 250, .repPeriodMs = 33 };

static bool kTest(int code) { return K.kKeyState[code / 8] >> (code % 8) & 1; }
// hidinput_hid_event() for an EV_KEY usage + input_get_disposition()
static void kernelKey(Dev* d, uint8_t* state, int usagePage, int usage, int code, int value) {
    if (!code || code == unk) return; // unmapped usage: ignored by hid-input
    bool cur = state[code / 8] >> (code % 8) & 1;
    if (cur == !!value) return; // no state change: the input core drops the event
    emit(d, EV_MSC, MSC_SCAN, usagePage << 16 | usage);
    emit(d, EV_KEY, code, value);
    state[code / 8] ^= 1 << (code % 8);
}
static void kbdFlush(void) {
    // input_pass_values(): "trigger auto repeat for key events"
    for (int i = 0; i < kbd.n; i++) {
        struct input_event* e = &kbd.frame[i];
        if (e->type != EV_KEY || e->value == 2 || K.repDelayMs <= 0) continue;
        if (e->value) { K.repeatKey = e->code; K.repeatAtNs = monoNs() + K.repDelayMs * 1000000LL; }
        else K.repeatKey = -1; // releasing ANY key stops the repeat, as in input_stop_autorepeat()
    }
    flushFrame(&kbd, 0);
}
// hid_input_report() for the boot keyboard report descriptor.
static void kernelKbdReport(const uint8_t r[8]) {
    kbd.reports++;
    logLine("kbd", "report\t%02x %02x %02x %02x %02x %02x %02x %02x", r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]);
    // Field 1: 8 one-bit Variable items, usages 0xE0..0xE7.
    for (int i = 0; i < 8; i++)
        if ((r[0] ^ K.kMods) >> i & 1) kernelKey(&kbd, K.kKeyState, 7, 0xE0 + i, hid_keyboard[0xE0 + i], r[0] >> i & 1);
    K.kMods = r[0];
    // Field 2: 6-byte Array. hid-core ignores the whole field on ErrorRollOver (usage 1).
    const uint8_t* v = r + 2; bool rollover = false;
    for (int n = 0; n < 6; n++) if (v[n] == 1) rollover = true;
    if (!rollover) {
        for (int n = 0; n < 6; n++) {
            if (K.kKeys[n] && !memchr(v, K.kKeys[n], 6)) kernelKey(&kbd, K.kKeyState, 7, K.kKeys[n], hid_keyboard[K.kKeys[n]], 0);
            if (v[n] && !memchr(K.kKeys, v[n], 6)) kernelKey(&kbd, K.kKeyState, 7, v[n], hid_keyboard[v[n]], 1);
        }
        memcpy(K.kKeys, v, 6);
    }
    kbdFlush();
}
static void fireTimers(void) { // input_repeat_key()
    while (K.repeatKey >= 0 && monoNs() >= K.repeatAtNs) {
        if (!kTest(K.repeatKey)) { K.repeatKey = -1; break; }
        emit(&kbd, EV_KEY, K.repeatKey, 2);
        flushFrame(&kbd, 1);
        if (logf_) fflush(logf_); // repeats also happen while we wait for the next command
        K.repeatAtNs += K.repPeriodMs * 1000000LL;
        if (K.repeatAtNs < monoNs() - 1000000000LL) K.repeatAtNs = monoNs(); // we were stalled; do not replay a backlog
    }
}
static void sleepUntil(int64_t tNs) { // sleeps while keeping the autorepeat timer running
    for (;;) {
        fireTimers();
        int64_t now = monoNs(), until = tNs;
        if (K.repeatKey >= 0 && K.repeatAtNs < until) until = K.repeatAtNs;
        if (until <= now) { if (tNs <= now) return; continue; }
        struct timespec ts = { until / 1000000000LL, until % 1000000000LL };
        clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL);
    }
}
static void waitSlot(Dev* d) { // a device answers at most one interrupt IN per polling interval
    if (d->intervalNs <= 0) return;
    int64_t now = monoNs();
    if (d->nextSlotNs > now) sleepUntil(d->nextSlotNs);
    d->nextSlotNs = monoNs() + d->intervalNs;
}
static void kbdSend(void) { // device firmware: build the report from the current key matrix state
    uint8_t r[8] = { K.mods, 0 };
    if (K.ndown > 6) memset(r + 2, 1, 6); // ErrorRollOver in every slot
    else memcpy(r + 2, K.down, K.ndown);
    waitSlot(&kbd);
    kernelKbdReport(r);
}
static void kbdKey(int usage, bool down) {
    if (usage >= 0xE0 && usage <= 0xE7) {
        if (down) K.mods |= 1 << (usage - 0xE0); else K.mods &= ~(1 << (usage - 0xE0));
    } else {
        uint8_t* p = memchr(K.down, usage, K.ndown);
        if (down && !p && K.ndown < 16) K.down[K.ndown++] = usage;
        if (!down && p) { memmove(p, p + 1, K.down + K.ndown - p - 1); K.ndown--; }
    }
    kbdSend();
}

// ---------------------------------------------------------------------------------------------
// Mouse: 5-byte report (buttons, dx, dy, wheel, pan) -> hid-input
static struct { uint8_t buttons; uint8_t kBtnState[KEY_CNT / 8 + 1]; uint8_t kButtons; int64_t sumX, sumY, sumWheel; } M;
static void kernelMouseReport(uint8_t buttons, int dx, int dy, int wheel, int pan) {
    mouse.reports++;
    logLine("mouse", "report\t%02x %02x %02x %02x %02x", buttons, dx & 0xff, dy & 0xff, wheel & 0xff, pan & 0xff);
    for (int i = 0; i < 8; i++) // usage page 9 (Button), usage i+1 -> BTN_MOUSE + i
        if ((buttons ^ M.kButtons) >> i & 1) kernelKey(&mouse, M.kBtnState, 9, i + 1, BTN_MOUSE + i, buttons >> i & 1);
    M.kButtons = buttons;
    if (dx) emit(&mouse, EV_REL, REL_X, dx); // the input core drops REL events with value 0
    if (dy) emit(&mouse, EV_REL, REL_Y, dy);
    if (wheel) { emit(&mouse, EV_REL, REL_WHEEL, wheel); emit(&mouse, EV_REL, REL_WHEEL_HI_RES, wheel * 120); } // hidinput_handle_scroll()
    if (pan) { emit(&mouse, EV_REL, REL_HWHEEL, pan); emit(&mouse, EV_REL, REL_HWHEEL_HI_RES, pan * 120); }
    M.sumX += dx; M.sumY += dy; M.sumWheel += wheel;
    flushFrame(&mouse, 0);
}
static void mouseSend(int dx, int dy, int wheel, int pan) { waitSlot(&mouse); kernelMouseReport(M.buttons, dx, dy, wheel, pan); }
static void mouseMove(int dx, int dy, int ms) {
    int big = abs(dx) > abs(dy) ? abs(dx) : abs(dy);
    int n = (big + 126) / 127; if (n < 1) n = 1;
    if (ms > 0 && mouse.intervalNs > 0) { int m = (int)((int64_t)ms * 1000000LL / mouse.intervalNs); if (m > n) n = m; }
    int sx = 0, sy = 0;
    for (int i = 1; i <= n; i++) { // exact integer interpolation: the per-report deltas sum to (dx, dy)
        int tx = (int)((int64_t)dx * i / n), ty = (int)((int64_t)dy * i / n);
        if (tx != sx || ty != sy) mouseSend(tx - sx, ty - sy, 0, 0);
        else if (mouse.intervalNs > 0) { sleepUntil(mouse.nextSlotNs); mouse.nextSlotNs = monoNs() + mouse.intervalNs; } // device NAKs: no report
        sx = tx; sy = ty;
    }
}

// ---------------------------------------------------------------------------------------------
// names
static int usageOfCode(int code) { for (int u = 4; u < 256; u++) if (hid_keyboard[u] == code) return u; return -1; }
static const struct { const char* name; int code; } aliases[] = {
    {"ctrl", KEY_LEFTCTRL}, {"control", KEY_LEFTCTRL}, {"lctrl", KEY_LEFTCTRL}, {"rctrl", KEY_RIGHTCTRL},
    {"shift", KEY_LEFTSHIFT}, {"lshift", KEY_LEFTSHIFT}, {"rshift", KEY_RIGHTSHIFT},
    {"alt", KEY_LEFTALT}, {"lalt", KEY_LEFTALT}, {"ralt", KEY_RIGHTALT}, {"altgr", KEY_RIGHTALT},
    {"meta", KEY_LEFTMETA}, {"super", KEY_LEFTMETA}, {"win", KEY_LEFTMETA}, {"cmd", KEY_LEFTMETA},
    {"enter", KEY_ENTER}, {"return", KEY_ENTER}, {"esc", KEY_ESC}, {"escape", KEY_ESC}, {"tab", KEY_TAB},
    {"space", KEY_SPACE}, {"backspace", KEY_BACKSPACE}, {"bksp", KEY_BACKSPACE}, {"delete", KEY_DELETE}, {"del", KEY_DELETE},
    {"insert", KEY_INSERT}, {"home", KEY_HOME}, {"end", KEY_END}, {"pageup", KEY_PAGEUP}, {"pagedown", KEY_PAGEDOWN},
    {"up", KEY_UP}, {"down", KEY_DOWN}, {"left", KEY_LEFT}, {"right", KEY_RIGHT}, {"capslock", KEY_CAPSLOCK},
};
// US layout: ASCII -> key code (+ shift). Unshifted and shifted rows of the same keys.
static const char usPlain[] = "`1234567890-=qwertyuiop[]\\asdfghjkl;'zxcvbnm,./ ";
static const char usShift[] = "~!@#$%^&*()_+QWERTYUIOP{}|ASDFGHJKL:\"ZXCVBNM<>? ";
static const int usCodes[] = {
    KEY_GRAVE, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0, KEY_MINUS, KEY_EQUAL,
    KEY_Q, KEY_W, KEY_E, KEY_R, KEY_T, KEY_Y, KEY_U, KEY_I, KEY_O, KEY_P, KEY_LEFTBRACE, KEY_RIGHTBRACE, KEY_BACKSLASH,
    KEY_A, KEY_S, KEY_D, KEY_F, KEY_G, KEY_H, KEY_J, KEY_K, KEY_L, KEY_SEMICOLON, KEY_APOSTROPHE,
    KEY_Z, KEY_X, KEY_C, KEY_V, KEY_B, KEY_N, KEY_M, KEY_COMMA, KEY_DOT, KEY_SLASH, KEY_SPACE };
static bool charToKey(char c, int* code, bool* shift) {
    if (c == '\n') { *code = KEY_ENTER; *shift = false; return true; }
    if (c == '\t') { *code = KEY_TAB; *shift = false; return true; }
    const char* p;
    if (c && (p = strchr(usPlain, c))) { *code = usCodes[p - usPlain]; *shift = false; return true; }
    if (c && (p = strchr(usShift, c))) { *code = usCodes[p - usShift]; *shift = true; return true; }
    return false;
}
// -> HID usage on page 7, or -1
static int parseKey(const char* s) {
    if (s[0] == 'u' && s[1] == '0' && s[2] == 'x') return (int)strtol(s + 1, NULL, 16);
    for (size_t i = 0; i < sizeof(aliases)/sizeof(aliases[0]); i++) if (!strcasecmp(s, aliases[i].name)) return usageOfCode(aliases[i].code);
    for (size_t i = 0; i < sizeof(keynames)/sizeof(keynames[0]); i++) if (!strcasecmp(s, keynames[i].name)) return usageOfCode(keynames[i].code);
    char buf[40]; snprintf(buf, sizeof(buf), "KEY_%s", s);
    for (size_t i = 0; i < sizeof(keynames)/sizeof(keynames[0]); i++) if (!strcasecmp(buf, keynames[i].name)) return usageOfCode(keynames[i].code);
    int code; bool shift;
    if (strlen(s) == 1 && charToKey(s[0], &code, &shift)) return usageOfCode(code);
    return -1;
}
static int parseButton(const char* s) {
    static const char* names[] = {"left", "right", "middle", "side", "extra"};
    for (int i = 0; i < 5; i++) if (!strcasecmp(s, names[i])) return i;
    return -1;
}

// ---------------------------------------------------------------------------------------------
// commands
static int cps = 10, holdMs = 30;
static uint64_t rng = 0x9E3779B97F4A7C15ULL;
static uint32_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint32_t)(rng >> 16); }
static int rndRange(int lo, int hi) { return lo + (int)(rnd() % (uint32_t)(hi - lo + 1)); }
static bool wantQuit = false;
static const char* runCommand(char* line);

static void tap(int usage, int ms) { kbdKey(usage, true); sleepUntil(monoNs() + ms * 1000000LL); kbdKey(usage, false); }
static void typeText(const char* text) {
    int64_t periodNs = 1000000000LL / (cps > 0 ? cps : 1), hold = holdMs * 1000000LL;
    if (hold > periodNs / 2) hold = periodNs / 2;
    int64_t t = monoNs();
    for (const char* p = text; *p; p++) {
        int code; bool shift;
        if (!charToKey(*p, &code, &shift)) { logLine("kbd", "error\tcannot type character 0x%02x", (unsigned char)*p); continue; }
        int usage = usageOfCode(code);
        if (shift) kbdKey(0xE1, true);
        kbdKey(usage, true);
        sleepUntil(t + hold);
        kbdKey(usage, false);
        if (shift) kbdKey(0xE1, false);
        t += periodNs;
        sleepUntil(t);
        if (monoNs() > t + periodNs) t = monoNs(); // cannot keep up (polling rate too low): do not accumulate debt
    }
}
static void unescape(char* s) {
    char* o = s;
    for (; *s; s++) {
        if (*s == '\\' && s[1]) { s++; *o++ = *s == 'n' ? '\n' : *s == 't' ? '\t' : *s; }
        else *o++ = *s;
    }
    *o = 0;
}
static void fuzz(int n, const char* what) {
    bool doK = strcmp(what, "mouse") != 0, doM = strcmp(what, "kbd") != 0;
    static const char* chordKeys[] = {"CTRL+A", "CTRL+E", "CTRL+C", "CTRL+V", "CTRL+X", "CTRL+Z", "CTRL+Y", "SHIFT+LEFT", "SHIFT+RIGHT", "SHIFT+UP", "SHIFT+DOWN"};
    static const char* navKeys[] = {"left", "right", "up", "down", "backspace", "delete", "enter", "home", "end", "tab"};
    static const char* btns[] = {"left", "right", "middle"};
    char cmd[256];
    for (int i = 0; i < n && !wantQuit; i++) {
        int r = rndRange(0, 99);
        if (!doM) r %= 50; else if (!doK) r = 50 + r % 50;
        if (r < 22) { // a short burst of text
            int len = rndRange(1, 12); char text[16];
            for (int j = 0; j < len; j++) text[j] = " abcdefghijklmnopqrstuvwxyzABCXYZ0123456789.,;()[]{}$-_=+/"[rndRange(0, 57)];
            text[len] = 0;
            snprintf(cmd, sizeof(cmd), "type %s", text);
        } else if (r < 34) snprintf(cmd, sizeof(cmd), "tap %s %d", navKeys[rndRange(0, 9)], rndRange(1, 40));
        else if (r < 40) snprintf(cmd, sizeof(cmd), "chord %s", chordKeys[rndRange(0, 10)]);
        else if (r < 43) snprintf(cmd, sizeof(cmd), "tap %s %d", navKeys[rndRange(0, 3)], rndRange(260, 600)); // long enough to autorepeat
        else if (r < 46) snprintf(cmd, sizeof(cmd), "cps %d", (int[]){5, 10, 20, 50, 100}[rndRange(0, 4)]);
        else if (r < 50) snprintf(cmd, sizeof(cmd), "sleep %d", rndRange(0, 60));
        else if (r < 72) snprintf(cmd, sizeof(cmd), "move %d %d", rndRange(-40, 40), rndRange(-40, 40));
        else if (r < 78) snprintf(cmd, sizeof(cmd), "move %d %d %d", rndRange(-900, 900), rndRange(-600, 600), rndRange(0, 200));
        else if (r < 86) snprintf(cmd, sizeof(cmd), "click %s %d %d", btns[rndRange(0, 9) < 8 ? 0 : rndRange(1, 2)], rndRange(1, 80), rndRange(1, 2));
        else if (r < 90) snprintf(cmd, sizeof(cmd), "button %s %s", btns[rndRange(0, 2)], rndRange(0, 1) ? "down" : "up");
        else if (r < 95) snprintf(cmd, sizeof(cmd), "wheel %d", rndRange(-5, 5));
        else if (r < 97) snprintf(cmd, sizeof(cmd), "hwheel %d", rndRange(-3, 3));
        else snprintf(cmd, sizeof(cmd), "sleep %d", rndRange(0, 60));
        const char* err = runCommand(cmd);
        if (err) logLine("emu", "error\tfuzz: %s", err);
    }
    strcpy(cmd, "releaseall"); runCommand(cmd);
}
// Returns NULL on success, else an error message.
static const char* runCommand(char* line) {
    static char err[160];
    while (isspace((unsigned char)*line)) line++;
    char* end = line + strlen(line);
    while (end > line && isspace((unsigned char)end[-1])) *--end = 0;
    if (!*line || *line == '#') return NULL;
    logLine("emu", "cmd\t%s", line);
    char verb[32]; int off = 0;
    if (sscanf(line, "%31s %n", verb, &off) < 1) return NULL;
    char* rest = line + off;
    char a[64] = "", b[64] = ""; int x = 0, y = 0, z = 0;
    if (!strcmp(verb, "key")) {
        if (sscanf(rest, "%63s %63s", a, b) != 2) return "usage: key down|up NAME";
        int u = parseKey(b); if (u < 0) { snprintf(err, sizeof(err), "unknown key %s", b); return err; }
        kbdKey(u, !strcmp(a, "down"));
    } else if (!strcmp(verb, "tap")) {
        x = holdMs; if (sscanf(rest, "%63s %d", a, &x) < 1) return "usage: tap NAME [holdms]";
        int u = parseKey(a); if (u < 0) { snprintf(err, sizeof(err), "unknown key %s", a); return err; }
        tap(u, x);
    } else if (!strcmp(verb, "chord")) {
        x = holdMs; if (sscanf(rest, "%63s %d", a, &x) < 1) return "usage: chord MOD+KEY [holdms]";
        int usages[8], n = 0;
        for (char* tok = strtok(a, "+"); tok && n < 8; tok = strtok(NULL, "+")) {
            int u = parseKey(tok); if (u < 0) { snprintf(err, sizeof(err), "unknown key %s", tok); return err; }
            usages[n++] = u;
        }
        for (int i = 0; i < n; i++) kbdKey(usages[i], true);
        sleepUntil(monoNs() + x * 1000000LL);
        for (int i = n - 1; i >= 0; i--) kbdKey(usages[i], false);
    } else if (!strcmp(verb, "type")) {
        size_t len = strlen(rest);
        if (len >= 2 && rest[0] == '"' && rest[len - 1] == '"') { rest[len - 1] = 0; rest++; unescape(rest); }
        typeText(rest);
    } else if (!strcmp(verb, "cps")) { cps = atoi(rest); if (cps < 1) cps = 1; }
    else if (!strcmp(verb, "hold")) holdMs = atoi(rest);
    else if (!strcmp(verb, "move")) {
        z = 0; if (sscanf(rest, "%d %d %d", &x, &y, &z) < 2) return "usage: move DX DY [MS]";
        mouseMove(x, y, z);
    } else if (!strcmp(verb, "button")) {
        if (sscanf(rest, "%63s %63s", a, b) != 2) return "usage: button NAME down|up";
        int bi = parseButton(a); if (bi < 0) return "unknown button";
        if (!strcmp(b, "down")) M.buttons |= 1 << bi; else M.buttons &= ~(1 << bi);
        mouseSend(0, 0, 0, 0);
    } else if (!strcmp(verb, "click")) {
        x = holdMs; y = 1; if (sscanf(rest, "%63s %d %d", a, &x, &y) < 1) return "usage: click NAME [holdms] [count]";
        int bi = parseButton(a); if (bi < 0) return "unknown button";
        for (int i = 0; i < y; i++) {
            M.buttons |= 1 << bi; mouseSend(0, 0, 0, 0);
            sleepUntil(monoNs() + x * 1000000LL);
            M.buttons &= ~(1 << bi); mouseSend(0, 0, 0, 0);
            if (i + 1 < y) sleepUntil(monoNs() + x * 1000000LL);
        }
    } else if (!strcmp(verb, "wheel") || !strcmp(verb, "hwheel")) {
        int n = atoi(rest), sign = n < 0 ? -1 : 1;
        // one detent per report, like a real ratcheted wheel
        for (int i = 0; i < abs(n); i++) { if (verb[0] == 'w') mouseSend(0, 0, sign, 0); else mouseSend(0, 0, 0, sign); }
    } else if (!strcmp(verb, "report")) {
        unsigned v[8] = {0}; int n = sscanf(rest, "%63s %x %x %x %x %x %x %x %x", a, &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7]);
        if (n < 2) return "usage: report kbd|mouse HEX...";
        if (!strcmp(a, "kbd")) { uint8_t r[8]; for (int i = 0; i < 8; i++) r[i] = v[i]; waitSlot(&kbd); kernelKbdReport(r); }
        else { waitSlot(&mouse); kernelMouseReport(v[0], (int8_t)v[1], (int8_t)v[2], (int8_t)v[3], (int8_t)v[4]); }
    } else if (!strcmp(verb, "rate")) {
        if (sscanf(rest, "%63s %d", a, &x) != 2) return "usage: rate kbd|mouse HZ";
        Dev* d = !strcmp(a, "kbd") ? &kbd : &mouse;
        d->intervalNs = x > 0 ? 1000000000LL / x : 0; d->nextSlotNs = 0;
    } else if (!strcmp(verb, "repeat")) {
        if (sscanf(rest, "%d %d", &x, &y) != 2) return "usage: repeat DELAYMS PERIODMS";
        K.repDelayMs = x; K.repPeriodMs = y; if (x <= 0) K.repeatKey = -1;
    } else if (!strcmp(verb, "sleep")) sleepUntil(monoNs() + (int64_t)(atof(rest) * 1000000.0));
    else if (!strcmp(verb, "mark")) { /* logged above */ }
    else if (!strcmp(verb, "releaseall")) {
        if (K.mods || K.ndown) { K.mods = 0; K.ndown = 0; kbdSend(); }
        if (M.buttons) { M.buttons = 0; mouseSend(0, 0, 0, 0); }
    } else if (!strcmp(verb, "seed")) { rng = strtoull(rest, NULL, 0) * 0x9E3779B97F4A7C15ULL + 0x1234567ULL; if (!rng) rng = 1; }
    else if (!strcmp(verb, "fuzz")) {
        strcpy(a, "all"); if (sscanf(rest, "%d %63s", &x, a) < 1) return "usage: fuzz N [kbd|mouse|all]";
        fuzz(x, a);
    } else if (!strcmp(verb, "stats")) {
        logLine("emu", "stats\tkbd reports %llu frames %llu events %llu dropped %llu; mouse reports %llu frames %llu events %llu dropped %llu sum %lld %lld wheel %lld",
                (unsigned long long)kbd.reports, (unsigned long long)kbd.frames, (unsigned long long)kbd.events, (unsigned long long)kbd.droppedFrames,
                (unsigned long long)mouse.reports, (unsigned long long)mouse.frames, (unsigned long long)mouse.events, (unsigned long long)mouse.droppedFrames,
                (long long)M.sumX, (long long)M.sumY, (long long)M.sumWheel);
    } else if (!strcmp(verb, "quit")) wantQuit = true;
    else { snprintf(err, sizeof(err), "unknown command %s", verb); return err; }
    if (logf_) fflush(logf_);
    return NULL;
}

// Reads lines from fd; while waiting for input the autorepeat timer keeps running.
static void runStream(int fd, int replyFd) {
    char buf[4096]; size_t len = 0; bool tooLong = false;
    while (!wantQuit) {
        char* nl;
        while ((nl = memchr(buf, '\n', len))) {
            *nl = 0;
            char line[4096]; strcpy(line, buf);
            size_t used = nl - buf + 1; memmove(buf, buf + used, len - used); len -= used;
            const char* err = runCommand(line);
            if (err) { logLine("emu", "error\t%s", err); if (!quiet) fprintf(stderr, "hidemu: %s\n", err); }
            if (replyFd >= 0) { char r[200]; int n = snprintf(r, sizeof(r), err ? "err %s\n" : "ok\n", err); if (write(replyFd, r, n) < 0) return; }
            if (wantQuit) return;
        }
        fireTimers();
        int timeout = -1;
        if (K.repeatKey >= 0) { int64_t d = (K.repeatAtNs - monoNs()) / 1000000LL; timeout = d < 0 ? 0 : (int)d + 1; }
        struct pollfd p = { fd, POLLIN, 0 };
        int pr = poll(&p, 1, timeout);
        if (pr <= 0) continue;
        if (len == sizeof(buf) - 1) { // no newline in 4095 bytes: drop the line (one reply) instead of mistaking it for EOF
            logLine("emu", "error\tline too long"); if (!quiet) fprintf(stderr, "hidemu: line too long\n");
            if (replyFd >= 0 && write(replyFd, "err line too long\n", 18) < 0) return;
            len = 0; tooLong = true;
        }
        ssize_t n = read(fd, buf + len, sizeof(buf) - 1 - len);
        if (n <= 0) { // EOF: run a last line without a newline
            if (len) { buf[len] = 0; runCommand(buf); }
            return;
        }
        len += n;
        if (tooLong) { // skip the rest of the dropped line
            char* nl2 = memchr(buf, '\n', len);
            if (!nl2) { len = 0; continue; }
            len -= nl2 + 1 - buf; memmove(buf, nl2 + 1, len); tooLong = false;
        }
    }
}

int main(int argc, char** argv) {
    const char* script = NULL; const char* ctl = NULL; const char* kbdPath = NULL; const char* mousePath = NULL;
    const char* fuzzArg = NULL; bool overflow = false;
    signal(SIGPIPE, SIG_IGN);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--kbd") && i + 1 < argc) kbdPath = argv[++i];
        else if (!strcmp(argv[i], "--mouse") && i + 1 < argc) mousePath = argv[++i];
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) { logf_ = fopen(argv[++i], "a"); if (!logf_) { perror("log"); return 1; } }
        else if (!strcmp(argv[i], "--script") && i + 1 < argc) script = argv[++i];
        else if (!strcmp(argv[i], "--ctl") && i + 1 < argc) ctl = argv[++i];
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) { char cmd[64]; snprintf(cmd, sizeof(cmd), "seed %s", argv[++i]); runCommand(cmd); }
        else if (!strcmp(argv[i], "--fuzz") && i + 1 < argc) fuzzArg = argv[++i];
        else if (!strcmp(argv[i], "--evdev-overflow")) overflow = true;
        else if (!strcmp(argv[i], "--quiet")) quiet = true;
        else { fprintf(stderr, "usage: %s [--kbd PATH] [--mouse PATH] [--log FILE] [--script FILE] [--ctl SOCKET] [--seed N] [--fuzz N[:kbd|mouse|all]] [--evdev-overflow] [--quiet]\n", argv[0]); return 2; }
    }
    if (logf_) setvbuf(logf_, NULL, _IOFBF, 1 << 16);
    if (kbdPath) devOpen(&kbd, kbdPath, overflow);
    if (mousePath) devOpen(&mouse, mousePath, overflow);
    logLine("emu", "start\tkbd=%s mouse=%s sizeof(struct input_event)=%zu", kbdPath ? kbdPath : "-", mousePath ? mousePath : "-", sizeof(struct input_event));

    if (fuzzArg) {
        char cmd[96], what[16] = "all"; int n = 0;
        sscanf(fuzzArg, "%d:%15s", &n, what);
        snprintf(cmd, sizeof(cmd), "fuzz %d %s", n, what); runCommand(cmd);
    } else if (ctl) {
        struct sockaddr_un addr = { .sun_family = AF_UNIX };
        strncpy(addr.sun_path, ctl, sizeof(addr.sun_path) - 1); unlink(ctl);
        int s = socket(AF_UNIX, SOCK_STREAM, 0);
        if (bind(s, (struct sockaddr*)&addr, sizeof(addr)) != 0 || listen(s, 4) != 0) { perror(ctl); return 1; }
        while (!wantQuit) { // one client at a time; every command is answered with "ok" or "err ..." once it has been fully emitted
            struct pollfd p = { s, POLLIN, 0 };
            fireTimers();
            if (poll(&p, 1, 20) <= 0) continue;
            int c = accept(s, NULL, NULL); if (c < 0) continue;
            runStream(c, c); close(c);
        }
        unlink(ctl);
    } else {
        int fd = 0;
        if (script && (fd = open(script, O_RDONLY)) < 0) { perror(script); return 1; }
        runStream(fd, -1);
    }
    char cmd[16] = "stats"; runCommand(cmd);
    if (logf_) fclose(logf_);
    return 0;
}
