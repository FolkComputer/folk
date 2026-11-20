// Folk Connect: find the Folk machines (and other people) on this
// network, and talk to them directly over WebRTC.

import { Signal } from './signal.js';
import { Link } from './link.js';
import { Pad } from './pad.js';
import { Sim } from './sim.js';
import { cleanDeviceName } from './statements.js';

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);

// By default there are no ICE servers at all, so connections only
// form between devices that can reach each other's local addresses.
// ?stun lets two browsers on different networks find each other; it
// makes no difference to Folk machines, which never use it.
const iceServers = params.has('stun') ? [{ urls: 'stun:stun.cloudflare.com:3478' }] : [];

const store = {
  get(key) { try { return localStorage.getItem(key); } catch { return null; } },
  set(key, value) { try { localStorage.setItem(key, value); } catch {} },
};

function defaultName() {
  const kind = matchMedia('(pointer: coarse)').matches ? 'phone' : 'computer';
  return `${kind}-${Math.random().toString(16).slice(2, 6)}`;
}

const state = {
  name: cleanDeviceName(store.get('connect-name') ?? '') || defaultName(),
  mode: params.has('sim') ? 'sim' : 'browser',
  roomName: decodeURIComponent(location.hash.slice(1)),
  peers: new Map(), // id -> {id, name, kind, caps}
  links: new Map(), // id -> Link
  cards: new Map(), // id -> <li>
  pad: null,        // {peerId, pad}
};
store.set('connect-name', state.name);

const sim = new Sim({ canvas: $('table'), statementsEl: $('sim-statements'), logEl: $('sim-log') });

const hello = () => ({
  name: state.mode === 'sim' ? `${state.name}-sim` : state.name,
  kind: state.mode,
  caps: state.mode === 'sim' ? ['folk', 'media'] : ['media'],
});

const signalUrl = () => {
  const url = new URL('ws', location.href);
  url.protocol = url.protocol.replace('http', 'ws');
  if (state.roomName) url.searchParams.set('room', state.roomName);
  return url.href;
};

const signal = new Signal({ url: signalUrl(), hello: hello() });

// --- Room ---

signal.addEventListener('up', ({ detail }) => {
  $('status').dataset.state = 'up';
  $('status-text').textContent = detail.room.label;
  $('room-label').textContent = detail.room.label;
  $('room-explain').textContent = detail.room.kind === 'network'
    ? 'Everyone who opens this page from the same network lands here.'
    : 'Anyone who knows this room name can see who is here, but can only connect from the same network.';

  // We have a new identity on the server, so links to other browsers
  // (which are keyed by it) are stale. A link to a Folk machine keeps
  // working: it does not need the server once it is up.
  for (const [id, link] of state.links) {
    if (state.pad?.peerId !== id) link.close();
  }
  for (const id of [...state.peers.keys()]) forgetPeer(id);
  for (const peer of detail.peers) addPeer(peer);
  renderRoster();
});
signal.addEventListener('down', () => {
  $('status').dataset.state = 'down';
  $('status-text').textContent = 'Reconnecting…';
});
signal.addEventListener('peer-joined', ({ detail }) => { addPeer(detail.peer); renderRoster(); });
signal.addEventListener('peer-left', ({ detail }) => {
  if (state.pad?.peerId !== detail.id) state.links.get(detail.id)?.close();
  forgetPeer(detail.id);
  renderRoster();
});
signal.addEventListener('signal', ({ detail }) => {
  if (!state.peers.has(detail.from) || !detail.data) return;
  linkTo(detail.from).onSignal(detail.data);
});
signal.addEventListener('server-error', ({ detail }) => console.warn('connect server:', detail.error));

function addPeer(peer) {
  state.peers.set(peer.id, { caps: [], ...peer });
}
function forgetPeer(id) {
  state.peers.delete(id);
  state.cards.get(id)?.remove();
  state.cards.delete(id);
}

// --- Links ---

function linkTo(peerId) {
  let link = state.links.get(peerId);
  if (link) return link;

  link = new Link({
    peerId,
    // Both ends must agree on who backs off when offers collide.
    polite: signal.id > peerId,
    send: (data) => signal.send(peerId, data),
    iceServers,
  });
  state.links.set(peerId, link);

  link.addEventListener('state', ({ detail }) => {
    if (detail === 'failed' || detail === 'closed') {
      if (state.links.get(peerId) === link) state.links.delete(peerId);
      if (detail === 'failed') link.pc.close();
      if (state.pad?.peerId === peerId) {
        padStatus('failed', detail === 'failed'
          ? 'Could not reach this machine directly. Is this device on the same network as it?'
          : 'The connection to this machine closed.');
      }
    }
    renderRoster();
    renderSimMedia();
  });
  link.addEventListener('streams', () => { renderRoster(); renderSimMedia(); });
  link.addEventListener('shared', renderRoster);
  link.addEventListener('channel', ({ detail: channel }) => {
    // Only a (simulated) Folk machine accepts these.
    if (state.mode !== 'sim') { channel.close(); return; }
    if (channel.label === 'folk') {
      sim.attach(channel, state.peers.get(peerId)?.name ?? peerId);
    } else if (channel.label === 'auth') {
      channel.addEventListener('message', () => channel.send('ok'));
    }
  });
  return link;
}

// --- Roster ---

const SHARES = [
  { what: 'screen', label: 'Share screen', get: () => navigator.mediaDevices.getDisplayMedia({ video: true, audio: true }),
    available: () => !!navigator.mediaDevices?.getDisplayMedia },
  { what: 'camera', label: 'Share camera', get: () => navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } }),
    available: () => !!navigator.mediaDevices?.getUserMedia },
  { what: 'mic', label: 'Share mic', get: () => navigator.mediaDevices.getUserMedia({ audio: true }),
    available: () => !!navigator.mediaDevices?.getUserMedia },
];

function makeCard(peer) {
  const card = $('peer-card').content.firstElementChild.cloneNode(true);
  card.dataset.peer = peer.id;
  card.querySelector('.kind').textContent =
    { folk: 'Folk', sim: 'simulated', browser: 'browser' }[peer.kind] ?? peer.kind;
  card.querySelector('.peer-name').textContent = peer.name;

  const actions = card.querySelector('.actions');
  if (peer.caps.includes('folk')) {
    const open = document.createElement('button');
    open.textContent = 'Open scratchpad';
    open.dataset.action = 'pad';
    open.addEventListener('click', () => openPad(peer.id));
    actions.append(open);
  }
  if (peer.caps.includes('media')) {
    for (const share of SHARES.filter((s) => s.available())) {
      const button = document.createElement('button');
      button.className = 'secondary';
      button.textContent = share.label;
      button.dataset.action = share.what;
      button.setAttribute('aria-pressed', 'false');
      button.addEventListener('click', () => toggleShare(peer.id, share));
      actions.append(button);
    }
  }
  return card;
}

async function toggleShare(peerId, share) {
  const existing = state.links.get(peerId);
  if (existing?.shared.has(share.what)) {
    existing.unshare(share.what);
    renderRoster();
    return;
  }
  let stream;
  try {
    stream = await share.get();
  } catch (err) {
    console.warn(`connect: ${share.what} not shared:`, err.message);
    return;
  }
  if (!state.peers.has(peerId)) {
    for (const track of stream.getTracks()) track.stop();
    return;
  }
  linkTo(peerId).share(share.what, stream);
  renderRoster();
}

// Keep one media element per incoming stream, so re-rendering does
// not restart playback.
function syncMedia(container, streams) {
  const wanted = new Set(streams.map((s) => s.id));
  for (const el of [...container.children]) {
    if (!wanted.has(el.dataset.stream)) el.remove();
  }
  for (const stream of streams) {
    if ([...container.children].some((el) => el.dataset.stream === stream.id)) continue;
    const hasVideo = stream.getVideoTracks().length > 0;
    const el = document.createElement(hasVideo ? 'video' : 'audio');
    el.dataset.stream = stream.id;
    el.srcObject = stream;
    el.autoplay = true;
    el.playsInline = true;
    el.controls = true;
    container.append(el);
  }
}

function renderRoster() {
  for (const peer of state.peers.values()) {
    let card = state.cards.get(peer.id);
    if (!card) {
      card = makeCard(peer);
      state.cards.set(peer.id, card);
      (peer.caps.includes('folk') ? $('machines') : $('people')).append(card);
    }
    const link = state.links.get(peer.id);
    const pill = card.querySelector('.link-state');
    pill.hidden = !link;
    if (link) {
      pill.textContent = link.state === 'new' ? 'connecting' : link.state;
      pill.dataset.state = link.state;
    }
    for (const button of card.querySelectorAll('button[aria-pressed]')) {
      button.setAttribute('aria-pressed', String(!!link?.shared.has(button.dataset.action)));
    }
    syncMedia(card.querySelector('.media'), link ? [...link.remoteStreams.values()] : []);
  }
  $('no-machines').hidden = $('machines').children.length > 0;
  $('no-people').hidden = $('people').children.length > 0;
}

function renderSimMedia() {
  if (state.mode !== 'sim') return;
  const streams = [...state.links.values()].flatMap((link) => [...link.remoteStreams.values()]);
  syncMedia($('sim-media'), streams);
}

// --- Views ---

function show(view) {
  for (const id of ['home', 'pad', 'sim']) $(id).hidden = id !== view;
}

function padStatus(status, problem = '') {
  const pill = $('pad-status');
  pill.textContent = status;
  pill.dataset.state = status;
  $('pad-problem').hidden = !problem;
  $('pad-problem').textContent = problem;
  for (const id of ['run', 'remove']) $(id).disabled = status !== 'connected';
}

function openPad(peerId) {
  const peer = state.peers.get(peerId);
  if (!peer || state.pad) return;
  // Start from a fresh link, so that closing the pad (which closes
  // the link) reliably releases what it held on the machine.
  state.links.get(peerId)?.close();
  $('pad-title').textContent = peer.name;
  show('pad');
  const pad = new Pad({ link: linkTo(peerId), peer, dev: state.name, onStatus: padStatus });
  state.pad = { peerId, pad };
}

function closePad() {
  state.pad?.pad.close();
  state.pad = null;
  show(state.mode === 'sim' ? 'sim' : 'home');
  renderRoster();
}

function setMode(mode) {
  if (state.pad) closePad();
  state.mode = mode;
  sim.reset();
  for (const link of state.links.values()) link.close();
  show(mode === 'sim' ? 'sim' : 'home');
  signal.rejoin(hello());
}

$('pad-back').addEventListener('click', closePad);
$('become-sim').addEventListener('click', () => setMode('sim'));
$('sim-stop').addEventListener('click', () => setMode('browser'));

$('name').value = state.name;
$('name').addEventListener('change', (e) => {
  state.name = cleanDeviceName(e.target.value) || defaultName();
  e.target.value = state.name;
  store.set('connect-name', state.name);
  signal.rejoin(hello());
});

$('room-name').value = state.roomName;
$('room-form').addEventListener('submit', (e) => {
  e.preventDefault();
  location.hash = $('room-name').value.trim();
});
window.addEventListener('hashchange', () => location.reload());

show(state.mode === 'sim' ? 'sim' : 'home');
renderRoster();

// For poking at from the console, and for the end-to-end tests.
window.connect = { state, signal, sim, linkTo };
