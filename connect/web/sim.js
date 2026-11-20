// A pretend Folk machine that lives in a browser tab.
//
// It cannot run Tcl. What it does is accept the same data channel a
// real machine would, read the statements that the scratchpad holds,
// and draw them: enough to try the phone side of things, or a new
// kind of input, without a projector in the room.

import { parseHold, readBody } from './statements.js';

const COLORS = ['#ffd166', '#5b9dff', '#ef476f', '#06d6a0', '#c792ea', '#ff9f1c'];

export class Sim {
  constructor({ canvas, statementsEl, logEl }) {
    this.canvas = canvas;
    this.statementsEl = statementsEl;
    this.logEl = logEl;
    this.clients = new Map(); // channel -> {name, color, holds: Map(key -> readBody result)}
    this.log = [];
    this.nextColor = 0;
    this.render();
  }

  // A scratchpad opened a "folk" channel to us.
  attach(channel, name) {
    const client = { name, color: COLORS[this.nextColor++ % COLORS.length], holds: new Map() };
    this.clients.set(channel, client);
    channel.addEventListener('message', (e) => this.onMessage(client, String(e.data)));
    channel.addEventListener('close', () => {
      // A real machine retracts everything the connection held.
      this.clients.delete(channel);
      this.render();
    });
    this.render();
  }

  onMessage(client, message) {
    this.log.push(`${client.name}: ${message.length > 400 ? message.slice(0, 400) + ' …' : message}`);
    if (this.log.length > 40) this.log.shift();

    const hold = parseHold(message);
    if (hold) {
      if (hold.body.trim() === '') client.holds.delete(hold.key);
      else client.holds.set(hold.key, readBody(hold.body));
    }
    this.render();
  }

  reset() {
    this.clients.clear();
    this.log = [];
    this.render();
  }

  // All statements currently held, as text.
  statements() {
    const lines = [];
    for (const client of this.clients.values()) {
      for (const held of client.holds.values()) {
        for (const words of held.statements) {
          if (words.includes('quad') || words.includes('geometry')) continue;
          if (held.code != null && words[3] === 'program' && words[4] === 'code') {
            // Show the code itself, not the base64 it travelled as.
            lines.push(`${words.slice(0, 5).join(' ')} {${held.code}}`);
            continue;
          }
          lines.push(words.map((w) => (/\s/.test(w) ? `{${w}}` : w)).join(' '));
        }
      }
    }
    return lines;
  }

  render() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = null;
      this.draw();
      this.statementsEl.textContent = this.statements().join('\n') || '(nothing yet)';
      this.logEl.textContent = this.log.join('\n');
    });
  }

  draw() {
    const { canvas } = this;
    const ctx = canvas.getContext('2d');
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);

    if (this.clients.size === 0) {
      ctx.fillStyle = '#666';
      ctx.font = '20px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.fillText('Waiting for a scratchpad to connect…', W / 2, H / 2);
      return;
    }

    for (const client of this.clients.values()) {
      const place = client.holds.get('quad')?.place;
      const code = client.holds.get('code')?.code;
      if (place && code != null) this.drawProgram(ctx, W, H, place, code);

      for (const held of client.holds.values()) {
        for (const words of held.statements) {
          // Claim <dev> has touch <id> at {x y}
          if (words[2] === 'has' && words[3] === 'touch' && words[5] === 'at') {
            const [x, y] = words[6].split(/\s+/).map(Number);
            this.drawTouch(ctx, x * W, y * H, client.color, words[1]);
          }
        }
      }
    }
  }

  drawProgram(ctx, W, H, place, code) {
    const w = place.width * W, h = place.height * H;
    ctx.save();
    ctx.translate(place.x * W + w / 2, place.y * H + h / 2);
    ctx.rotate((place.angle ?? 0) * Math.PI / 180);

    // The two decorations that the default program asks for.
    const outline = code.match(/is outlined (\w+)/);
    ctx.strokeStyle = outline ? outline[1] : '#888';
    ctx.lineWidth = outline ? 4 : 1;
    ctx.strokeRect(-w / 2, -h / 2, w, h);

    const label = code.match(/is labelled "([^"]*)"/);
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    if (label) {
      ctx.font = `${Math.max(14, Math.min(34, h / 4))}px system-ui, sans-serif`;
      ctx.fillText(label[1], 0, 0, w - 12);
    } else {
      ctx.font = '13px ui-monospace, monospace';
      ctx.fillStyle = '#9aa';
      code.split('\n').slice(0, 5).forEach((line, i) => ctx.fillText(line, 0, -26 + i * 16, w - 12));
    }
    ctx.restore();
  }

  drawTouch(ctx, x, y, color, label) {
    ctx.beginPath();
    ctx.arc(x, y, 22, 0, Math.PI * 2);
    ctx.fillStyle = color + '44';
    ctx.fill();
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    ctx.stroke();
    ctx.fillStyle = color;
    ctx.font = '13px system-ui, sans-serif';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'alphabetic';
    ctx.fillText(label, x, y - 30);
  }
}
