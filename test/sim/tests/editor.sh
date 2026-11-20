#!/bin/bash
# editor.sh -- full-boot test of the emulated tabletop: Folk's real
# on-table editor driven by an emulated USB keyboard, raw keys to a
# target that handles keyboard input, and emulated mice.
#
#   test/sim/tests/editor.sh        (exit 0 = pass, 1 = fail)
#
# Boots ./folk headless with an isolated $HOME, loads
# test/sim/programs/{sim-setup,table}.folk and editor-table.folk,
# drives test/sim/hidemu, checks statements (POST of Tcl to the web
# server) and pixels of captured frames (GET /display-frame).
#
# Environment: SIM_PORT (default 4312), SIM_OUT (where the frames go,
# default /tmp/folk-sim-editor), SIM_TIMEOUT (seconds, default 180).

set -u
cd "$(dirname "$0")/../../.."
PORT=${SIM_PORT:-4312}
OUT=${SIM_OUT:-/tmp/folk-sim-editor}
URL=http://127.0.0.1:$PORT
HIDEMU=test/sim/hidemu/hidemu
make -s -C test/sim/hidemu || exit 1

TMP=$(mktemp -d /tmp/folk-sim-editor.XXXXXX)
mkdir -p "$OUT" "$TMP/home/folk-data/local-program"
cp test/sim/programs/sim-setup.folk test/sim/programs/table.folk \
   test/sim/tests/editor-table.folk "$TMP/home/folk-data/local-program/"

HOME=$TMP/home FOLK_SIM_DIR=$TMP FOLK_WEB_PORT=$PORT FOLK_PID_FILE=$TMP/folk.pid \
    FOLK_HEADLESS=1280x720 TERM=dumb \
    timeout -k 5 "${SIM_TIMEOUT:-180}" ./folk > "$TMP/folk.out" 2>&1 &
TIMEOUT_PID=$!

cleanup() {
    # Folk is the leader of its own process group (boot.folk).
    local pid; pid=$(tr -d ' ' < "$TMP/folk.pid" 2>/dev/null)
    kill "$TIMEOUT_PID" 2>/dev/null
    if [ -n "$pid" ]; then
        kill -TERM -- "-$pid" 2>/dev/null; sleep 0.3; kill -KILL -- "-$pid" 2>/dev/null
        # Folk's per-program logs: kept (with its output) if the test failed.
        if [ "$FAILED" = 0 ]; then rm -rf "/var/tmp/folk-$pid"; else echo "logs: /var/tmp/folk-$pid $OUT/folk.out"; fi
    fi
    wait "$TIMEOUT_PID" 2>/dev/null
    cp "$TMP/folk.out" "$OUT/folk.out" 2>/dev/null
    rm -rf "$TMP"
}
FAILED=0
trap cleanup EXIT

fail() { echo "FAIL: $*"; FAILED=1; }
pass() { echo "ok: $*"; }
# Evaluates Tcl inside Folk (on the web server's thread).
tcl() { curl -s -m 20 -X POST --data-binary "$1" "$URL/"; }
# wait_for SECONDS WHAT TCL: until TCL evaluates to 1.
wait_for() {
    local deadline=$(( $(date +%s) + $1 ))
    while [ "$(tcl "$3")" != "1" ]; do
        if [ "$(date +%s)" -ge "$deadline" ]; then fail "$2 (still not true after $1 s: $3)"; return 1; fi
        if ! kill -0 "$TIMEOUT_PID" 2>/dev/null; then fail "$2 (Folk is gone)"; return 1; fi
        sleep 0.2
    done
    pass "$2"
}
frame() { curl -s -m 30 -o "$OUT/$1" "$URL/display-frame"; }
# pixels FRAME X0 Y0 X1 Y1 KIND: how many pixels in the rect are white/green/red/lit.
pixels() {
    python3 - "$OUT/$1" "$2" "$3" "$4" "$5" "$6" <<'EOF'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
x0, y0, x1, y1 = map(int, sys.argv[2:6])
kinds = {"white": lambda r, g, b: r > 200 and g > 200 and b > 200,
         "green": lambda r, g, b: g > 100 and r < 60 and b < 60,
         "red": lambda r, g, b: r > 200 and g < 60 and b < 60,
         "lit": lambda r, g, b: r + g + b > 60}
print(sum(1 for y in range(y0, y1) for x in range(x0, x1) if kinds[sys.argv[6]](*im.getpixel((x, y)))))
EOF
}
# wait_frame SECONDS WHAT FRAME CONDITION: captures FRAME until the shell
# CONDITION holds for it (drawing lags behind the statements).
wait_frame() {
    local deadline=$(( $(date +%s) + $1 ))
    while frame "$3"; ! eval "$4"; do
        if [ "$(date +%s)" -ge "$deadline" ]; then fail "$2 (see $OUT/$3)"; return 1; fi
        sleep 0.3
    done
    pass "$2"
}
# hidemu DEVICE-ARGS... : runs the commands on stdin, then exits (the
# events stay in the FIFOs, which the table keeps open).
emu() { timeout 60 "$HIDEMU" --quiet --log "$OUT/hidemu.log" "$@"; }
rm -f "$OUT/hidemu.log"

wait_for 90 "Folk booted and the display is up" \
    'expr {[llength [Query! display headless has width 1280 height 720]] == 1}' || exit 1

# (a) A virtual page runs its code and draws at its pixel rect.
wait_for 30 "(a) sim-page runs its code" 'llength [Query! sim-page is version one]'
wait_for 30 "(a) sim-flag has a canvas and a quad" \
    'expr {[llength [Query! sim-flag has canvas /c/ with /...o/]] == 1 && [llength [Query! sim-flag has quad /q/]] == 1}'

# (b) The keyboard page below sim-page makes the real editor appear on it.
wait_for 60 "(b) sim-kbd is typing into an editor on sim-page" \
    'expr {[llength [Query! sim-kbd is typing into {sim-kbd editor}]] == 1 &&
           [llength [Query! editor {sim-kbd editor} has selected program sim-page]] == 1 &&
           [llength [Query! editor {sim-kbd editor} has viewport size /s/]] == 1}'
INITIAL='
Wish $this is outlined white
Claim $this is version one
'
wait_for 30 "(b) the editor buffer holds the page's code" \
    "expr {[dict get [lindex [Query! editor buffer for sim-page is /code/] 0] code] eq {$INITIAL}}"
# keyboard.folk must be reading the FIFO and the editor must be listening.
wait_for 60 "(b) keyboard.folk has opened the emulated keyboards" \
    "expr {[llength [Query! $TMP/kbd0 has keymaps /m/]] == 1 && [llength [Query! $TMP/kbd1 has keymaps /m/]] == 1}"
wait_for 30 "(b) the editor subscribes to sim-kbd's keys" \
    "expr {[llength [Query! subscribe keyboard $TMP/kbd0 claims key /k/ is /s/ with /...o/ /body/ with environment /e/]] >= 1}"
# The outline is 6 px wide; the editor's dashed outline is animated, so we
# look at its text area only.
wait_frame 30 "(a) sim-flag's outline is drawn on its pixel rect, and nothing inside it" editor-before.png \
    '[ "$(pixels editor-before.png 80 500 280 600 white)" -gt 3000 ] && [ "$(pixels editor-before.png 90 510 270 590 lit)" -eq 0 ]
     [ "$(pixels editor-before.png 70 490 290 610 lit)" -eq "$(pixels editor-before.png 80 500 280 600 lit)" ]'
wait_frame 30 "(b) the editor is drawn on sim-page (line numbers, empty first line)" editor-before.png \
    '[ "$(pixels editor-before.png 92 74 108 140 lit)" -gt 30 ] && [ "$(pixels editor-before.png 112 74 300 88 white)" -eq 0 ]'

# (c) Typing edits the buffer and shows up on the table.
emu --kbd "$TMP/kbd0" <<'EOF'
cps 40
type "Claim $this is edited"
tap enter
EOF
wait_for 30 "(c) typing on the emulated keyboard edits the editor buffer" \
    "expr {[dict get [lindex [Query! editor buffer for sim-page is /code/] 0] code] eq {Claim \$this is edited
$INITIAL}}"
wait_frame 30 "(c) the typed text is visible in the frame (line 1 of the editor)" editor-typed.png \
    '[ "$(pixels editor-typed.png 112 74 300 88 white)" -gt 150 ]'

# (d) Ctrl+S re-runs the page with the new code.
[ "$(tcl 'llength [Query! sim-page is edited]')" = "0" ] || fail "(d) sim-page is edited before saving"
emu --kbd "$TMP/kbd0" <<'EOF'
chord CTRL+S
EOF
wait_for 30 "(d) Ctrl+S re-runs sim-page with the typed code" \
    'expr {[llength [Query! sim-page is edited]] == 1 && [llength [Query! sim-page is version one]] == 1}'
wait_frame 30 "(d) sim-flag turned green in the frame" editor-saved.png \
    '[ "$(pixels editor-saved.png 100 520 260 580 green)" -eq 9600 ]'

# (e) A target that handles keyboard input gets raw keys, not an editor.
wait_for 30 "(e) sim-combo is typing into sim-app, without an editor" \
    'expr {[llength [Query! sim-combo is typing into sim-app]] == 1 && [llength [Query! sim-combo has created editor /e/]] == 0}'
wait_for 30 "(e) sim-app subscribes to sim-combo's keys" \
    "expr {[llength [Query! subscribe keyboard $TMP/kbd1 claims key /k/ is /s/ with /...o/ /body/ with environment /e/]] >= 1}"
emu --kbd "$TMP/kbd1" <<'EOF'
type "Ok"
tap enter
EOF
wait_for 30 "(e) sim-app got the raw keys Shift O k Return" \
    'expr {[lmap r [lsort -integer -index 3 [lmap r [Query! sim-app got key /key/ with seq /seq/] {list key [dict get $r key] seq [dict get $r seq]}]] {dict get $r key}] eq {Shift O k Return}}'

# (f) Mice: the combo page drives the target its keyboard types into;
# a mouse page drives what it points up at.
wait_for 30 "(f) sim-combo is pointing into sim-app, sim-mouse into sim-pad" \
    'expr {[llength [Query! sim-combo is pointing into sim-app]] == 1 && [llength [Query! sim-mouse is pointing into sim-pad]] == 1 &&
           [llength [Query! /p/ is pointing into /t/]] == 2}'
wait_for 30 "(f) the targets subscribe to the mouse reports" \
    "expr {[llength [Query! subscribe mouse $TMP/mouse1 claims report with /...r/ /body/ with environment /e/]] == 1 &&
           [llength [Query! subscribe mouse $TMP/mouse0 claims report with /...r/ /body/ with environment /e/]] == 1}"
emu --mouse "$TMP/mouse1" <<'EOF'
move 60 -40 100
click left
move 100 0
button left down
move -100 0 50
EOF
emu --mouse "$TMP/mouse0" <<'EOF'
move -30 50
move 500 0
move -70 0 80
EOF
# sim-app is 400x300: center (200, 150) + (60, -40); sim-pad is 160x300: (80, 150) + (-30, 50), then clamped at x = 159, - 70.
wait_for 30 "(f) sim-app's pointer followed mouse1 (left button held, 1 click before)" \
    'llength [Query! sim-app has pointer 260 110 buttons 1 clicks 2]'
wait_for 30 "(f) sim-pad's pointer followed mouse0 (clamped at the page edge)" \
    'llength [Query! sim-pad has pointer 89 200 buttons 0 clicks 0]'
# (Each page should show one pointer, a disc of about 150 pixels, and nothing else
# above y = 330, where the green dot of the keyboard page's whisker begins.)
wait_frame 30 "(f) both pointers are drawn where they should be (red = button held)" editor-mouse.png \
    '[ "$(pixels editor-mouse.png 896 166 904 174 red)" -eq 64 ] && [ "$(pixels editor-mouse.png 1165 256 1173 264 white)" -eq 64 ] &&
     [ "$(pixels editor-mouse.png 650 70 1030 330 lit)" -lt 200 ] && [ "$(pixels editor-mouse.png 1090 70 1230 330 lit)" -lt 200 ]'

# Nothing we loaded may have failed (audio, terminal and music fail on a box
# without a sound card, libghostty and sclang).
ERRORS=$(tcl 'join [lmap r [Query! /p/ has error /e/ with info /i/] {
    if {[regexp {(audio|terminal|music)\.folk$} [dict get $r p]]} { continue }
    format "%s: %s" [dict get $r p] [string range [dict get $r e] 0 300]}] "\n"')
[ -z "$ERRORS" ] && pass "no program has an error" || fail "programs with errors:
$ERRORS"

echo "frames: $OUT/editor-{before,typed,saved,mouse}.png"
if [ "$FAILED" = 0 ]; then echo "PASS"; else echo "FAIL (Folk's output: $(tail -5 "$TMP/folk.out"))"; fi
exit $FAILED
