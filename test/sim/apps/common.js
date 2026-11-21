// common.js -- shared instrumentation for the sim test apps.
//
// Every app is laid out for a 1024x640 viewport, calls `sim.init({...})` once, and gets:
//
//   window.__state()        JSON-serialisable app state
//   window.__stableState()  the same minus the app's volatile keys (timestamps etc.): equal after
//                           equal abstract actions, whatever drove them
//   window.__hash()         24-bit hash of __stableState(): FNV-1a (32 bit) over the UTF-8 bytes of
//                           the JSON with object keys sorted, masked with 0xFFFFFF
//   window.__layout()       {testid: {x, y, w, h}} of every visible [data-testid], viewport px
//   window.__events()       the event log (array of records, see below)
//   window.__pointer()      {x, y, buttons, moves}: last trusted mouse position (not in the state)
//
// Event log. One compact record per TRUSTED DOM event, plus app-level semantic actions:
//   {i, t, k, ...}   i = sequence number from 0, t = performance.now() in ms (0.1 ms resolution)
//   k = "load"                                   {app, w, h, dpr}
//   k = "keydown" | "keyup"                      {key, code, m, r, tid}      m = modifier bits
//       (shift 1, ctrl 2, alt 4, meta 8), r = 1 for autorepeat, tid = data-testid under the target
//   k = "beforeinput" | "input"                  {it: inputType, d: data, tid}
//   k = "mousedown" | "mouseup" | "click" | "dblclick" | "contextmenu"
//                                                {x, y, b: button, bs: buttons, n: detail, m, tid}
//   k = "wheel"                                  {x, y, dx, dy, tid}
//   k = "app"                                    {a: action name, ...}       from sim.action()
// With ?session=ID in the URL the records are POSTed in batches (at most every 50 ms; sendBeacon
// on pagehide) to /log?session=ID as
//   {app, load, p, events: [...], state, hash, layout?}     (layout only when it changed)
// (see ../appserver.py). Without a session nothing is sent.
//
// Status strip. The bottom 24 px of the viewport (y = 616..639) encode state in solid colour
// blocks, so that a pixel oracle can read it from a captured projector frame. Block b covers
// x = 24*b .. 24*b+23; sample its centre (24*b + 12, 628) and threshold each channel at 128:
// digit = 4*(R > 128) + 2*(G > 128) + (B > 128), i.e. one octal digit per block
// (0 black, 1 blue, 2 green, 3 cyan, 4 red, 5 magenta, 6 yellow, 7 white).
//   blocks 0..4    7 0 4 2 1 (white black red green blue): locates the strip, checks channels
//   blocks 5..6    app id, 2 octal digits, most significant first
//                  (events 1, paint 2, kanban 3, editor 4, form 5, synth 6)
//   blocks 7..10   number of DOM event records logged so far, mod 4096 (4 octal digits)
//   blocks 11..18  __hash() (8 octal digits)
//   block  19      flags: 1 (blue) a mouse button is down, 2 (green) a key is down,
//                  4 (red) the app is modal (dialog, menu or find bar open)
//   block  20      7 (white): end marker
// The rest of the strip is a human-readable copy: "<app> n=<count> h=<hash hex>".
(function () {
  'use strict';
  var PALETTE = ['#000000', '#0000ff', '#00ff00', '#00ffff', '#ff0000', '#ff00ff', '#ffff00', '#ffffff'];
  var NBLOCKS = 21;
  var params = new URLSearchParams(location.search);
  var session = params.get('session');
  var loadId = Date.now().toString(36) + Math.random().toString(36).slice(2, 8);

  var sim = window.sim = {
    app: '?', appId: 0, getState: function () { return {}; }, volatile: [], isModal: function () { return false; },
    log: [], pointer: { x: 0, y: 0, buttons: 0, moves: 0 }, keysDown: {}, ready: false
  };
  var seq = 0, domCount = 0, pending = [], postSeq = 0, flushTimer = null;
  var lastLayoutJson = '', lastStateJson = null, lastPostedStateJson = null, lastHash = 0, lastStrip = '';
  var blocks = [], readout = null;

  function tid(el) {
    el = el && el.closest ? el.closest('[data-testid]') : null;
    return el ? el.getAttribute('data-testid') : null;
  }
  function mods(e) { return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0); }
  function push(k, data) {
    var rec = { i: seq++, t: Math.round(performance.now() * 10) / 10, k: k };
    for (var key in data) rec[key] = data[key];
    sim.log.push(rec); pending.push(rec);
    schedule();
    return rec;
  }
  sim.action = function (a, data) {
    var rec = { a: a };
    for (var key in (data || {})) rec[key] = data[key];
    return push('app', rec);
  };
  sim.tid = tid;

  function canonical(v) {
    if (v === null || typeof v !== 'object') return JSON.stringify(v === undefined ? null : v);
    if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
    return '{' + Object.keys(v).sort().filter(function (k) { return v[k] !== undefined; }).map(function (k) {
      return JSON.stringify(k) + ':' + canonical(v[k]);
    }).join(',') + '}';
  }
  function fnv1a(str) {
    var bytes = new TextEncoder().encode(str), h = 0x811c9dc5;
    for (var i = 0; i < bytes.length; i++) { h ^= bytes[i]; h = Math.imul(h, 0x01000193) >>> 0; }
    return h >>> 0;
  }
  sim.fnv1a = fnv1a;
  sim.canonical = canonical;

  window.__state = function () { return sim.getState(); };
  window.__stableState = function () {
    var s = sim.getState(), out = {};
    for (var k in s) if (sim.volatile.indexOf(k) < 0) out[k] = s[k];
    return out;
  };
  window.__hash = function () { return fnv1a(canonical(window.__stableState())) & 0xFFFFFF; };
  window.__events = function () { return sim.log; };
  window.__pointer = function () { return sim.pointer; };
  window.__layout = function () {
    var out = {};
    var els = document.querySelectorAll('[data-testid]');
    for (var i = 0; i < els.length; i++) {
      var r = els[i].getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      var st = getComputedStyle(els[i]);
      if (st.visibility === 'hidden' || st.display === 'none') continue;
      out[els[i].getAttribute('data-testid')] = {
        x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height)
      };
    }
    return out;
  };

  // ---- trusted DOM events
  function onKey(e) {
    if (!e.isTrusted) return;
    if (e.type === 'keydown') sim.keysDown[e.code] = true; else delete sim.keysDown[e.code];
    domCount++;
    push(e.type, { key: e.key, code: e.code, m: mods(e), r: e.repeat ? 1 : 0, tid: tid(e.target) });
  }
  function onInput(e) {
    if (!e.isTrusted) return;
    domCount++;
    push(e.type, { it: e.inputType || '', d: e.data === undefined ? null : e.data, tid: tid(e.target) });
  }
  function onMouse(e) {
    if (!e.isTrusted) return;
    sim.pointer.x = e.clientX; sim.pointer.y = e.clientY; sim.pointer.buttons = e.buttons;
    domCount++;
    push(e.type, { x: e.clientX, y: e.clientY, b: e.button, bs: e.buttons, n: e.detail, m: mods(e), tid: tid(e.target) });
  }
  function onWheel(e) {
    if (!e.isTrusted) return;
    domCount++;
    push('wheel', { x: e.clientX, y: e.clientY, dx: e.deltaX, dy: e.deltaY, tid: tid(e.target) });
  }
  // A native drag (HTML5 drag and drop, or dragging selected text) swallows the mouse: after
  // dragstart there are no mousemoves and no mouseup, only drag events. Log its ends, and keep
  // following the pointer.
  function onDrag(e) {
    if (!e.isTrusted) return;
    if (e.type !== 'dragstart') { sim.pointer.x = e.clientX; sim.pointer.y = e.clientY; }
    if (e.type === 'dragend') sim.pointer.buttons = 0;
    if (e.type !== 'dragover') push(e.type, { x: e.clientX, y: e.clientY, tid: tid(e.target) });
  }
  ['dragstart', 'dragover', 'drop', 'dragend'].forEach(function (t) { window.addEventListener(t, onDrag, true); });
  ['keydown', 'keyup'].forEach(function (t) { window.addEventListener(t, onKey, true); });
  ['beforeinput', 'input'].forEach(function (t) { window.addEventListener(t, onInput, true); });
  ['mousedown', 'mouseup', 'click', 'dblclick', 'contextmenu'].forEach(function (t) { window.addEventListener(t, onMouse, true); });
  window.addEventListener('wheel', onWheel, { capture: true, passive: true });
  window.addEventListener('mousemove', function (e) {
    if (!e.isTrusted) return;
    sim.pointer.x = e.clientX; sim.pointer.y = e.clientY; sim.pointer.buttons = e.buttons; sim.pointer.moves++;
  }, true);
  // never a native context menu; apps show their own
  window.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  window.addEventListener('blur', function () { sim.keysDown = {}; });

  // ---- status strip
  function buildStrip() {
    var strip = document.createElement('div');
    strip.id = 'sim-strip';
    strip.setAttribute('data-testid', 'strip');
    strip.style.cssText = 'position:fixed;left:0;top:616px;width:1024px;height:24px;background:#000;z-index:9999;overflow:hidden;';
    for (var b = 0; b < NBLOCKS; b++) {
      var d = document.createElement('div');
      d.style.cssText = 'position:absolute;top:0;width:24px;height:24px;left:' + (24 * b) + 'px;background:#000;';
      strip.appendChild(d); blocks.push(d);
    }
    readout = document.createElement('div');
    readout.style.cssText = 'position:absolute;left:' + (24 * NBLOCKS + 16) + 'px;top:0;height:24px;line-height:24px;' +
      'color:#fff;font:14px/24px "DejaVu Sans Mono",monospace;white-space:pre;';
    strip.appendChild(readout);
    document.body.appendChild(strip);
  }
  function octal(n, digits) {
    var out = [];
    for (var i = digits - 1; i >= 0; i--) out.push(Math.floor(n / Math.pow(8, i)) % 8);
    return out;
  }
  function refresh() {
    if (!sim.ready) return;
    var stateJson = canonical(window.__stableState());
    if (stateJson !== lastStateJson) { lastStateJson = stateJson; lastHash = fnv1a(stateJson) & 0xFFFFFF; }
    var flags = (sim.pointer.buttons ? 1 : 0) | (Object.keys(sim.keysDown).length ? 2 : 0) | (sim.isModal() ? 4 : 0);
    var digits = [7, 0, 4, 2, 1].concat(octal(sim.appId, 2), octal(domCount % 4096, 4), octal(lastHash, 8), [flags, 7]);
    var key = digits.join('');
    if (key === lastStrip) return;
    lastStrip = key;
    for (var b = 0; b < NBLOCKS; b++) blocks[b].style.background = PALETTE[digits[b]];
    readout.textContent = sim.app + ' n=' + domCount + ' h=' + ('00000' + lastHash.toString(16)).slice(-6);
  }
  sim.refresh = refresh;

  // ---- reporting
  function schedule() {
    if (flushTimer === null) flushTimer = setTimeout(flush, 50);
    // the strip should follow the event that caused the change, not wait for the batch
    Promise.resolve().then(refresh);
    setTimeout(refresh, 0);
  }
  function flush(beacon) {
    if (flushTimer !== null) { clearTimeout(flushTimer); flushTimer = null; }
    if (!sim.ready) return;
    refresh();
    if (!session) { pending = []; return; }
    var layoutJson = JSON.stringify(window.__layout());
    var layoutChanged = layoutJson !== lastLayoutJson;
    if (!pending.length && !layoutChanged && lastStateJson === lastPostedStateJson) return;
    lastPostedStateJson = lastStateJson;
    var batch = { app: sim.app, load: loadId, p: postSeq++, events: pending, state: window.__state(), hash: lastHash };
    if (layoutChanged) { batch.layout = JSON.parse(layoutJson); lastLayoutJson = layoutJson; }
    pending = [];
    var body = JSON.stringify(batch), url = '/log?session=' + encodeURIComponent(session);
    if (beacon === true && navigator.sendBeacon) { navigator.sendBeacon(url, body); return; }
    fetch(url, { method: 'POST', body: body, keepalive: body.length < 60000 }).catch(function () {});
  }
  sim.flush = flush;
  window.addEventListener('pagehide', function () { flush(true); });

  sim.init = function (opts) {
    sim.app = opts.app; sim.appId = opts.id; sim.getState = opts.state;
    sim.volatile = opts.volatile || [];
    if (opts.modal) sim.isModal = opts.modal;
    buildStrip();
    sim.ready = true;
    push('load', { app: sim.app, w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio });
    refresh();
    setInterval(flush, 200);   // catches changes no event announced (timers, scrolling)
  };
})();
