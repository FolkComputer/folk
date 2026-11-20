import test from 'node:test';
import assert from 'node:assert/strict';

import {
  handleMessage, handleClose, roomFor, normalizeIp, sanitizeHello, LIMITS,
} from '../server/room.js';

const room = { kind: 'network', label: 'this network' };
const hello = (extra = {}) => JSON.stringify({ type: 'hello', name: 'a', kind: 'browser', ...extra });

// A tiny in-memory room that applies results the way the servers do.
function makeRoom() {
  const peers = [];
  const inbox = new Map();
  let n = 0;
  return {
    peers,
    inbox,
    join() {
      const peer = { id: `p${n++}`, info: null };
      peers.push(peer);
      inbox.set(peer.id, []);
      return peer;
    },
    send(peer, raw) {
      const result = handleMessage(peer, raw, room, peers);
      if (result.info) peer.info = result.info;
      for (const { to, msg } of result.out) inbox.get(to).push(msg);
      return result;
    },
    leave(peer) {
      peers.splice(peers.indexOf(peer), 1);
      for (const { to, msg } of handleClose(peer, peers).out) inbox.get(to).push(msg);
    },
  };
}

test('peers in a room see each other once they say hello', () => {
  const r = makeRoom();
  const a = r.join();
  const b = r.join();

  r.send(a, hello({ name: 'folk-hex', kind: 'folk', caps: ['folk'] }));
  assert.deepEqual(r.inbox.get(a.id), [
    { type: 'welcome', id: a.id, room, peers: [] },
  ]);
  // b has connected but not said hello: it hears nothing.
  assert.deepEqual(r.inbox.get(b.id), []);

  r.send(b, hello({ name: 'phone' }));
  assert.deepEqual(r.inbox.get(b.id)[0].peers, [
    { id: a.id, name: 'folk-hex', kind: 'folk', caps: ['folk'] },
  ]);
  assert.deepEqual(r.inbox.get(a.id)[1], {
    type: 'peer-joined',
    peer: { id: b.id, name: 'phone', kind: 'browser', caps: [] },
  });
});

test('signals are relayed verbatim to one peer, tagged with the sender', () => {
  const r = makeRoom();
  const [a, b, c] = [r.join(), r.join(), r.join()];
  for (const p of [a, b, c]) r.send(p, hello());
  for (const p of [a, b, c]) r.inbox.get(p.id).length = 0;

  const data = { description: { type: 'offer', sdp: 'v=0...' } };
  r.send(a, JSON.stringify({ type: 'signal', to: b.id, data }));
  assert.deepEqual(r.inbox.get(b.id), [{ type: 'signal', from: a.id, data }]);
  assert.deepEqual(r.inbox.get(c.id), []);
  assert.deepEqual(r.inbox.get(a.id), []);
});

test('you cannot signal before hello, or to a peer that is not there', () => {
  const r = makeRoom();
  const [a, b] = [r.join(), r.join()];
  r.send(b, hello());

  r.send(a, JSON.stringify({ type: 'signal', to: b.id, data: 1 }));
  assert.equal(r.inbox.get(a.id).at(-1).type, 'error');
  assert.equal(r.inbox.get(b.id).length, 1);

  r.send(b, JSON.stringify({ type: 'signal', to: a.id, data: 1 }));
  assert.match(r.inbox.get(b.id).at(-1).error, /no such peer/);
});

test('leaving tells the others, but only if you were visible', () => {
  const r = makeRoom();
  const [a, b, lurker] = [r.join(), r.join(), r.join()];
  r.send(a, hello());
  r.send(b, hello());

  r.leave(lurker);
  assert.equal(r.inbox.get(a.id).filter((m) => m.type === 'peer-left').length, 0);

  r.leave(b);
  assert.deepEqual(r.inbox.get(a.id).at(-1), { type: 'peer-left', id: b.id });
});

test('bad input is rejected without throwing', () => {
  const r = makeRoom();
  const a = r.join();
  assert.equal(r.send(a, 'not json').out[0].msg.type, 'error');
  assert.equal(r.send(a, 'null').out[0].msg.type, 'error');
  assert.equal(r.send(a, '{"type":"nope"}').out[0].msg.type, 'error');
  assert.equal(r.send(a, 'x'.repeat(LIMITS.maxMessageBytes + 1)).close, true);
  assert.equal(r.send(a, new Uint8Array(4)).close, true);

  r.send(a, hello());
  assert.match(r.send(a, hello()).out[0].msg.error, /already/);
  assert.deepEqual(r.send(a, '{"type":"ping"}').out, [{ to: a.id, msg: { type: 'pong' } }]);
});

test('a full room turns new peers away', () => {
  const r = makeRoom();
  for (let i = 0; i < LIMITS.maxPeers; i++) r.send(r.join(), hello());
  const extra = r.join();
  const result = r.send(extra, hello());
  assert.equal(result.close, true);
  assert.equal(extra.info, null);
});

test('hello is sanitized', () => {
  assert.deepEqual(sanitizeHello({ name: ' a\u0000b\n ', kind: 'evil', caps: 'x' }),
    { name: 'ab', kind: 'browser', caps: [] });
  assert.equal(sanitizeHello({ name: 'x'.repeat(100) }).name.length, LIMITS.maxNameLength);
  assert.deepEqual(sanitizeHello({ caps: ['folk', 3, '', 'pairing'] }).caps, ['folk', 'pairing']);
});

test('rooms: same address shares a room, names override', async () => {
  const a = await roomFor({ ip: '203.0.113.7' });
  const b = await roomFor({ ip: '::ffff:203.0.113.7' });
  const c = await roomFor({ ip: '203.0.113.8' });
  assert.equal(a.key, b.key);
  assert.notEqual(a.key, c.key);
  assert.equal(a.kind, 'network');
  assert.ok(!a.key.includes('203'));

  const named = await roomFor({ room: 'My Table!', ip: '203.0.113.7' });
  assert.deepEqual(named, { key: 'name:mytable', kind: 'named', label: 'mytable' });
  // A name that sanitizes to nothing falls back to the network room.
  assert.equal((await roomFor({ room: '!!!', ip: '203.0.113.7' })).key, a.key);
});

test('IPv6 addresses are grouped by /64', () => {
  assert.equal(normalizeIp('2001:db8:1:2:aaaa:bbbb:cccc:dddd'), '2001:db8:1:2::/64');
  assert.equal(normalizeIp('2001:db8:1:2::1'), '2001:db8:1:2::/64');
  assert.equal(normalizeIp('2001:0db8:0001:0002::1'), '2001:db8:1:2::/64');
  assert.equal(normalizeIp('::1'), '0:0:0:0::/64');
  assert.equal(normalizeIp('198.51.100.1'), '198.51.100.1');
});
