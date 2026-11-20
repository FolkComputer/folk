// The Tcl that the scratchpad sends to a Folk machine, and (for the
// simulator) the reverse: reading that Tcl back into something a
// browser can draw.
//
// `tcl`, `loadList` and `loadDict` come from Folk's own folk.js.

/* global tcl, loadList, loadDict */

// Everything this page holds on the machine, so it can all be
// released when the connection goes away.
export const HOLD_KEYS = ['touches', 'tilt', 'mic', 'canv', 'quad', 'code'];

// Runs inside FolkWS.send(), where $this is the connection.
export const cleanupTcl = () =>
  `On unmatch {\n${HOLD_KEYS.map((k) => `  Hold! -on $this -key ${k} {}`).join('\n')}\n}`;

const round = (n, places = 4) => Number(n.toFixed(places));

// Device names end up as bare words in Tcl, so keep them to
// characters that cannot start a substitution.
export const cleanDeviceName = (name) =>
  String(name).toLowerCase().replace(/[^a-z0-9_-]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);

// touches: [{id, x, y}] with x and y as fractions of the display,
// measured from its top-left corner.
export const touchesTcl = (dev, touches) => touches
  .map((t) => tcl`Claim ${dev} has touch ${t.id} at ${[round(t.x), round(t.y)]}`)
  .join('\n');

// Degrees, as the browser reports them: alpha is the compass-like
// rotation about the axis out of the screen, beta is front-to-back
// tilt, gamma is left-to-right tilt.
export const tiltTcl = (dev, { alpha, beta, gamma }) =>
  tcl`Claim ${dev} has orientation ${{ alpha: round(alpha, 1), beta: round(beta, 1), gamma: round(gamma, 1) }}`;

// 0 (silence) to 1 (as loud as the microphone reports).
export const micTcl = (dev, level) => tcl`Claim ${dev} has audio level ${round(level, 3)}`;

export const canvasTcl = (program) => tcl`Wish ${program} has a canvas`;

// base64 keeps backslash-newlines in the code intact (see
// builtin-programs/web/new.folk).
export const codeTcl = (program, code) => {
  const bytes = new TextEncoder().encode(code);
  const b64 = btoa(String.fromCharCode(...bytes));
  return tcl`package require base64
Claim ${program} has program code [binary decode base64 ${b64}]`;
};

// place: {x, y, width, height, angle}. x, y, width and height are
// fractions of the display (x, y is the top-left corner); angle is in
// degrees. This is the same projection as builtin-programs/web/new.folk:
// a quad 1.5m in front of the projector that lands on those pixels.
export const quadTcl = (program, place) => {
  const p = {
    x: round(place.x), y: round(place.y),
    width: round(place.width), height: round(place.height),
    angle: round(place.angle, 1),
  };
  return tcl`set place ${p}
package require linalg
namespace import ::math::linearalgebra::add
namespace import ::math::linearalgebra::sub
namespace import ::math::linearalgebra::matmul
namespace import ::math::linearalgebra::scale

Require! the quad library is /quadLib/
Require! display /disp/ has width /displayWidth/ height /displayHeight/
Require! display $disp has intrinsics /displayIntrinsics/

set depth 1.5
set fx [dict get $displayIntrinsics fx]
set fy [dict get $displayIntrinsics fy]
set cx [dict get $displayIntrinsics cx]
set cy [dict get $displayIntrinsics cy]
set iw [dict get $displayIntrinsics width]
set ih [dict get $displayIntrinsics height]

set x1 [expr {([dict get $place x] * $iw - $cx) * $depth / $fx}]
set y1 [expr {([dict get $place y] * $ih - $cy) * $depth / $fy}]
set x2 [expr {(([dict get $place x] + [dict get $place width]) * $iw - $cx) * $depth / $fx}]
set y2 [expr {(([dict get $place y] + [dict get $place height]) * $ih - $cy) * $depth / $fy}]
set vertices [list \
    [list $x1 $y1 $depth] [list $x2 $y1 $depth] \
    [list $x2 $y2 $depth] [list $x1 $y2 $depth]]

set angle [expr {[dict get $place angle] * 3.14159265 / 180.0}]
set c [expr {cos($angle)}]
set s [expr {sin($angle)}]
set R [list [list $c [expr {-1.0 * $s}] 0.0] \
            [list $s $c 0.0] \
            [list 0.0 0.0 1.0]]
lassign $vertices v1 v2 v3 v4
set centroid [scale 0.25 [add [add $v1 $v2] [add $v3 $v4]]]
set rotated [list]
foreach v $vertices {
    lappend rotated [add [matmul $R [sub $v $centroid]] $centroid]
}

Claim ${program} has resolved geometry \
    [list width [expr {$x2 - $x1}] height [expr {$y2 - $y1}]]
Claim ${program} has quad [$quadLib create "display $disp" $rotated]`;
};

// --- Reading it back (simulator) ---

// A FolkWS.hold() arrives as:
//   Hold! -noncapturing -on $chan -key <key> <body>
// Returns {key, body}, or null for anything else.
export function parseHold(message) {
  let words;
  try { words = loadList(message); } catch { return null; }
  if (words[0] !== 'Hold!') return null;
  const k = words.indexOf('-key');
  if (k === -1 || k + 2 >= words.length) return null;
  return { key: words[k + 1], body: words[words.length - 1] };
}

// Picks out what the simulator knows how to draw from a held body:
//   statements - the Claim/Wish lines, as lists of words
//   place      - from quadTcl
//   code       - from codeTcl
export function readBody(body) {
  const result = { statements: [], place: null, code: null };

  const place = body.match(/^set place (.*)$/m);
  if (place) {
    try {
      const dict = loadDict(loadList(place[1])[0]);
      result.place = Object.fromEntries(Object.entries(dict).map(([k, v]) => [k, Number(v)]));
    } catch {}
  }

  const code = body.match(/has program code \[binary decode base64 ([A-Za-z0-9+/=]*)\]/);
  if (code) {
    try {
      const bytes = Uint8Array.from(atob(code[1]), (ch) => ch.charCodeAt(0));
      result.code = new TextDecoder().decode(bytes);
    } catch {}
  }

  // Join backslash-continued lines, as Tcl would.
  for (let line of body.replace(/\\\n\s*/g, ' ').split('\n')) {
    line = line.trim();
    if (!/^(Claim|Wish) /.test(line)) continue;
    try { result.statements.push(loadList(line)); } catch {}
  }
  return result;
}
