// Room logic for the Folk connect signaling server.
//
// This file is pure (no sockets, no storage) so the same code runs in
// the Cloudflare Durable Object (worker.js), the Node dev server
// (dev-server.js), and the unit tests.
//
// Protocol (JSON text frames over one WebSocket per peer):
//
//   client -> server
//     {type: "hello", name, kind: "folk"|"browser"|"sim", caps: [...]}
//     {type: "signal", to: <peer id>, data: <anything>}
//     {type: "ping"}
//
//   server -> client
//     {type: "welcome", id, room: {kind, label}, peers: [peer...]}
//     {type: "peer-joined", peer}
//     {type: "peer-left", id}
//     {type: "signal", from: <peer id>, data}
//     {type: "pong"}
//     {type: "error", error}
//
// The server never looks inside `data`; it is the WebRTC offer/answer
// and ICE candidates that the two peers exchange so that they can
// talk to each other directly.

export const LIMITS = {
  maxPeers: 32,
  maxMessageBytes: 64 * 1024,
  maxNameLength: 40,
  maxCaps: 16,
  maxCapLength: 24,
};

const KINDS = ['folk', 'browser', 'sim'];

export function newPeerId() {
  const bytes = crypto.getRandomValues(new Uint8Array(6));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

// Peers that share a public address share a room, which is how a
// phone finds the Folk machines on its own network without typing
// anything. IPv6 hosts each get their own address, so we group those
// by /64 prefix instead.
export function normalizeIp(ip) {
  ip = String(ip ?? '').trim().toLowerCase();
  const mapped = ip.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
  if (mapped) return mapped[1];
  if (!ip.includes(':')) return ip;

  const [head, tail = ''] = ip.split('::');
  const headParts = head ? head.split(':') : [];
  const tailParts = tail ? tail.split(':') : [];
  const fill = ip.includes('::') ? 8 - headParts.length - tailParts.length : 0;
  const parts = [...headParts, ...Array(Math.max(fill, 0)).fill('0'), ...tailParts];
  return parts.slice(0, 4).map((p) => p.replace(/^0+(?=.)/, '')).join(':') + '::/64';
}

export function sanitizeRoomName(name) {
  if (typeof name !== 'string') return '';
  return name.toLowerCase().replace(/[^a-z0-9_-]/g, '').slice(0, 48);
}

// Returns {key, kind, label}. `key` names the room (and the Durable
// Object); we hash the address so that it is not kept around as an
// identifier.
export async function roomFor({ room, ip }) {
  const name = sanitizeRoomName(room);
  if (name) return { key: `name:${name}`, kind: 'named', label: name };

  const data = new TextEncoder().encode(`folk-connect:${normalizeIp(ip)}`);
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', data));
  const hex = Array.from(digest.slice(0, 12), (b) => b.toString(16).padStart(2, '0')).join('');
  return { key: `net:${hex}`, kind: 'network', label: 'this network' };
}

function cleanString(s, max) {
  if (typeof s !== 'string') return '';
  // Strip control characters; names are shown in other people's UIs.
  return s.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, max);
}

export function sanitizeHello(msg) {
  const caps = Array.isArray(msg.caps) ? msg.caps : [];
  return {
    name: cleanString(msg.name, LIMITS.maxNameLength) || 'anonymous',
    kind: KINDS.includes(msg.kind) ? msg.kind : 'browser',
    caps: caps.slice(0, LIMITS.maxCaps)
      .map((c) => cleanString(c, LIMITS.maxCapLength))
      .filter(Boolean),
  };
}

const describe = (peer) => ({ id: peer.id, ...peer.info });

// A peer is {id, info}; `info` is null until it has said hello, and
// until then nobody else in the room can see it or hear from it.
//
// Returns {info, out, close}:
//   info  - new info for `self` if it changed (the caller stores it)
//   out   - [{to: <peer id>, msg}] messages to deliver
//   close - true if the caller should drop this connection
export function handleMessage(self, raw, room, peers) {
  const reply = (msg) => ({ to: self.id, msg });
  const fail = (error, close = false) => ({ out: [reply({ type: 'error', error })], close });

  if (typeof raw !== 'string') return fail('expected a text frame', true);
  if (raw.length > LIMITS.maxMessageBytes) return fail('message too large', true);

  let msg;
  try { msg = JSON.parse(raw); } catch { return fail('expected JSON'); }
  if (msg === null || typeof msg !== 'object') return fail('expected a JSON object');

  const others = peers.filter((p) => p.id !== self.id && p.info);

  switch (msg.type) {
    case 'ping':
      return { out: [reply({ type: 'pong' })] };

    case 'hello': {
      if (self.info) return fail('already said hello');
      if (others.length >= LIMITS.maxPeers) return fail('room is full', true);

      const info = sanitizeHello(msg);
      const me = { id: self.id, info };
      return {
        info,
        out: [
          reply({
            type: 'welcome',
            id: self.id,
            room: { kind: room.kind, label: room.label },
            peers: others.map(describe),
          }),
          ...others.map((p) => ({ to: p.id, msg: { type: 'peer-joined', peer: describe(me) } })),
        ],
      };
    }

    case 'signal': {
      if (!self.info) return fail('say hello first');
      const target = others.find((p) => p.id === msg.to);
      if (!target) return fail(`no such peer: ${cleanString(String(msg.to), 24)}`);
      return { out: [{ to: target.id, msg: { type: 'signal', from: self.id, data: msg.data } }] };
    }

    default:
      return fail('unknown message type');
  }
}

export function handleClose(self, peers) {
  if (!self.info) return { out: [] };
  return {
    out: peers
      .filter((p) => p.id !== self.id && p.info)
      .map((p) => ({ to: p.id, msg: { type: 'peer-left', id: self.id } })),
  };
}
