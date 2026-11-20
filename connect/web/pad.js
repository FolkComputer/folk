// The scratchpad: one open session with one Folk machine (real or
// simulated). It speaks Folk's ordinary WebSocket protocol, carried
// over a WebRTC data channel named "folk".

/* global FolkWS, tcl */

import {
  cleanupTcl, touchesTcl, tiltTcl, micTcl, canvasTcl, codeTcl, quadTcl,
} from './statements.js';

const $ = (id) => document.getElementById(id);

function loadToken(machine) {
  try { return localStorage.getItem(`connect-token:${machine}`); } catch { return null; }
}
function saveToken(machine, token) {
  try { localStorage.setItem(`connect-token:${machine}`, token); } catch {}
}

function once(target, ...events) {
  return new Promise((resolve) => {
    for (const name of events) {
      target.addEventListener(name, (e) => resolve({ name, event: e }), { once: true });
    }
  });
}

export class Pad {
  constructor({ link, peer, dev, onStatus }) {
    this.link = link;
    this.peer = peer;
    this.dev = dev;
    this.onStatus = onStatus;
    this.closed = false;

    this.program = `web-program-connect-${dev}-${Math.random().toString(16).slice(2, 8)}`;
    this.place = { x: 0.35, y: 0.3, width: 0.3, height: 0.3, angle: 0 };
    this.running = false;
    this.touches = new Map();
    this.held = new Map(); // key -> Tcl, for the "what the machine sees" view
    this.dirty = new Set();
    this.cleanups = [];

    this.bindUi();
    this.start().catch((err) => {
      console.error('pad:', err);
      if (!this.closed) this.onStatus('failed', String(err.message ?? err));
    });
  }

  async start() {
    this.onStatus('connecting');
    if (this.peer.caps.includes('pairing')) await this.pair();
    if (this.closed) return;

    let made = false;
    this.folk = new FolkWS(null, () => {
      // FolkWS reconnects by asking for a new socket. A dropped data
      // channel means the whole link is gone, so decline.
      if (made) return null;
      made = true;
      const channel = this.channel = this.link.channel('folk');
      channel.addEventListener('close', () => {
        if (!this.closed) this.onStatus('failed', 'The connection to this machine closed.');
      });
      return channel;
    });

    await this.folk.connected;
    if (this.closed) return;
    this.folk.send(cleanupTcl());
    this.folk.watchCollected(
      tcl`${this.program} has error /something/ with info /errorInfo/`,
      (errors) => this.showErrors(errors));
    this.onStatus('connected');
    this.refreshInputs();
  }

  // Some machines ask for a code (shown on the machine) the first
  // time a device connects, and hand back a token for next time.
  async pair() {
    const channel = this.link.channel('auth');
    const opened = await once(channel, 'open', 'close');
    if (opened.name === 'close') throw new Error('Could not reach this machine.');

    const ask = async (text) => {
      channel.send(text);
      const reply = await once(channel, 'message', 'close');
      return reply.name === 'message' ? String(reply.event.data) : 'no';
    };
    const accept = (reply) => {
      const [status, token] = reply.split(' ');
      if (status !== 'ok') return false;
      if (token) saveToken(this.peer.name, token);
      return true;
    };

    const token = loadToken(this.peer.name);
    let ok = token ? accept(await ask(`token ${token}`)) : false;
    for (let tries = 0; !ok && tries < 3 && !this.closed; tries++) {
      const code = window.prompt(
        `Enter the pairing code shown on ${this.peer.name}` + (tries ? ' (that code was not right)' : ''));
      if (code === null) break;
      ok = accept(await ask(`code ${code.trim()}`));
    }
    channel.close();
    if (!ok) throw new Error('This machine needs a pairing code.');
  }

  // --- Sending ---

  // Holds are coalesced to one send per key per animation frame, so
  // a fast finger does not flood the channel.
  hold(key, program) {
    this.held.set(key, program);
    this.dirty.add(key);
    if (this.flushing || !this.folk || this.closed) return;
    this.flushing = requestAnimationFrame(() => {
      this.flushing = null;
      if (this.closed || this.channel?.readyState !== 'open') return;
      for (const k of this.dirty) this.folk.hold(k, this.held.get(k));
      this.dirty.clear();
      this.showHeld();
    });
  }

  showHeld() {
    const parts = [];
    for (const key of ['touches', 'tilt', 'mic']) {
      if (this.held.get(key)) parts.push(this.held.get(key));
    }
    if (this.running) parts.push(`# program ${this.program}\n# at ${JSON.stringify(this.place)}`);
    $('pad-statements').textContent = parts.join('\n') || '(nothing held)';
  }

  showErrors(errors) {
    const el = $('error');
    el.hidden = errors.length === 0;
    el.textContent = errors.map((e) => e.errorInfo).join('\n');
  }

  run() {
    this.running = true;
    this.hold('canv', canvasTcl(this.program));
    this.hold('code', codeTcl(this.program, $('code').value));
    this.hold('quad', quadTcl(this.program, this.place));
    this.layoutProgram();
  }

  remove() {
    this.running = false;
    for (const key of ['code', 'quad', 'canv']) this.hold(key, '');
    this.showErrors([]);
    this.layoutProgram();
  }

  layoutProgram() {
    const el = $('program');
    el.hidden = !this.running;
    const p = this.place;
    Object.assign(el.style, {
      left: `${p.x * 100}%`, top: `${p.y * 100}%`,
      width: `${p.width * 100}%`, height: `${p.height * 100}%`,
      transform: `rotate(${p.angle}deg)`,
    });
  }

  refreshInputs() {
    this.setTilt($('send-tilt').checked);
    this.setMic($('send-mic').checked);
    this.sendTouches();
  }

  sendTouches() {
    const on = $('send-touches').checked;
    const touches = on ? [...this.touches.entries()].map(([id, t]) => ({ id, ...t })) : [];
    this.hold('touches', touchesTcl(this.dev, touches));
  }

  async setTilt(on) {
    this.stopTilt?.();
    this.stopTilt = null;
    if (!on) { this.hold('tilt', ''); return; }

    try {
      // iOS asks for permission, and only from a tap.
      const permission = await window.DeviceOrientationEvent?.requestPermission?.();
      if (permission && permission !== 'granted') throw new Error('denied');
    } catch {
      $('send-tilt').checked = false;
      return;
    }
    let last = 0;
    const onTilt = (e) => {
      if (e.alpha == null || performance.now() - last < 100) return;
      last = performance.now();
      this.hold('tilt', tiltTcl(this.dev, e));
    };
    window.addEventListener('deviceorientation', onTilt);
    this.stopTilt = () => window.removeEventListener('deviceorientation', onTilt);
  }

  async setMic(on) {
    this.stopMic?.();
    this.stopMic = null;
    if (!on) { this.hold('mic', ''); return; }

    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      $('send-mic').checked = false;
      return;
    }
    const audio = new AudioContext();
    const analyser = audio.createAnalyser();
    analyser.fftSize = 1024;
    audio.createMediaStreamSource(stream).connect(analyser);
    const samples = new Float32Array(analyser.fftSize);
    const timer = setInterval(() => {
      analyser.getFloatTimeDomainData(samples);
      let sum = 0;
      for (const s of samples) sum += s * s;
      this.hold('mic', micTcl(this.dev, Math.min(1, Math.sqrt(sum / samples.length) * 4)));
    }, 100);
    this.stopMic = () => {
      clearInterval(timer);
      for (const track of stream.getTracks()) track.stop();
      audio.close();
    };
  }

  // --- UI ---

  listen(target, type, handler, options) {
    target.addEventListener(type, handler, options);
    this.cleanups.push(() => target.removeEventListener(type, handler, options));
  }

  bindUi() {
    const surface = $('surface');
    const programEl = $('program');
    const fraction = (e) => {
      const r = surface.getBoundingClientRect();
      return {
        x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
        y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)),
      };
    };

    let drag = null; // {pointerId, dx, dy} while moving the program
    const dots = new Map();

    this.listen(surface, 'pointerdown', (e) => {
      surface.setPointerCapture(e.pointerId);
      const at = fraction(e);
      if (e.target === programEl || programEl.contains(e.target)) {
        drag = { pointerId: e.pointerId, dx: at.x - this.place.x, dy: at.y - this.place.y };
        return;
      }
      this.touches.set(e.pointerId, at);
      const dot = document.createElement('div');
      dot.className = 'touch-dot';
      surface.append(dot);
      dots.set(e.pointerId, dot);
      moveDot(e.pointerId, at);
      this.sendTouches();
    });
    const moveDot = (id, at) => {
      const dot = dots.get(id);
      if (dot) { dot.style.left = `${at.x * 100}%`; dot.style.top = `${at.y * 100}%`; }
    };
    this.listen(surface, 'pointermove', (e) => {
      const at = fraction(e);
      if (drag?.pointerId === e.pointerId) {
        this.place.x = at.x - drag.dx;
        this.place.y = at.y - drag.dy;
        this.layoutProgram();
        if (this.running) this.hold('quad', quadTcl(this.program, this.place));
      } else if (this.touches.has(e.pointerId)) {
        this.touches.set(e.pointerId, at);
        moveDot(e.pointerId, at);
        this.sendTouches();
      }
    });
    const end = (e) => {
      if (drag?.pointerId === e.pointerId) drag = null;
      if (this.touches.delete(e.pointerId)) {
        dots.get(e.pointerId)?.remove();
        dots.delete(e.pointerId);
        this.sendTouches();
      }
    };
    this.listen(surface, 'pointerup', end);
    this.listen(surface, 'pointercancel', end);
    this.cleanups.push(() => { for (const dot of dots.values()) dot.remove(); });

    this.listen($('run'), 'click', () => this.run());
    this.listen($('remove'), 'click', () => this.remove());
    this.listen($('angle'), 'input', (e) => {
      this.place.angle = Number(e.target.value);
      this.layoutProgram();
      if (this.running) this.hold('quad', quadTcl(this.program, this.place));
    });
    this.listen($('code'), 'keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 's' || e.key === 'Enter')) {
        e.preventDefault();
        this.run();
      }
    });
    this.listen($('send-touches'), 'change', () => this.sendTouches());
    this.listen($('send-tilt'), 'change', (e) => this.setTilt(e.target.checked));
    this.listen($('send-mic'), 'change', (e) => this.setMic(e.target.checked));

    $('angle').value = 0;
    this.showErrors([]);
    this.showHeld();
    this.layoutProgram();
  }

  close() {
    this.closed = true;
    this.stopTilt?.();
    this.stopMic?.();
    for (const cleanup of this.cleanups) cleanup();
    $('program').hidden = true;
    // Closing the link is what tells the machine to let go of
    // everything this pad was holding.
    this.link.close();
  }
}
