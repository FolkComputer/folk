// Local stand-in for the Cloudflare Worker: serves web/ and speaks
// the same signaling protocol (it runs the same room.js).
//
//   node server/dev-server.js [port]
//
// Then open http://localhost:8787 in two tabs, or point a Folk
// machine at it with:
//
//   Assert! the connect server is "ws://<this machine>:8787/ws"

import http from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';

import { handleMessage, handleClose, roomFor, newPeerId } from './room.js';

const here = fileURLToPath(new URL('.', import.meta.url));
const webDir = join(here, '..', 'web');
const folkJs = join(here, '..', '..', 'lib', 'folk.js');

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.json': 'application/json',
  '.webmanifest': 'application/manifest+json',
};

export function startServer(port = 8787) {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    let path = normalize(decodeURIComponent(url.pathname));
    if (path.endsWith('/')) path += 'index.html';
    // folk.js lives in the main repo; `npm run build` copies it into
    // web/ for deployment.
    const file = path === '/folk.js' ? folkJs : join(webDir, path);
    if (file !== folkJs && !file.startsWith(webDir)) {
      res.writeHead(403).end();
      return;
    }
    try {
      const body = await readFile(file);
      res.writeHead(200, {
        'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream',
        'Cache-Control': 'no-store',
      });
      res.end(body);
    } catch {
      res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found');
    }
  });

  // room key -> Map(peer id -> {id, info, ws})
  const rooms = new Map();
  const wss = new WebSocketServer({ noServer: true, maxPayload: 256 * 1024 });

  server.on('upgrade', async (req, socket, head) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname !== '/ws') { socket.destroy(); return; }
    const room = await roomFor({
      room: url.searchParams.get('room'),
      ip: req.socket.remoteAddress,
    });
    wss.handleUpgrade(req, socket, head, (ws) => join_(ws, room));
  });

  function join_(ws, room) {
    if (!rooms.has(room.key)) rooms.set(room.key, new Map());
    const peers = rooms.get(room.key);
    const self = { id: newPeerId(), info: null, ws };
    peers.set(self.id, self);

    const deliver = (out) => {
      for (const { to, msg } of out) peers.get(to)?.ws.send(JSON.stringify(msg));
    };

    ws.on('message', (data, isBinary) => {
      const raw = isBinary ? data : data.toString('utf8');
      const result = handleMessage(self, raw, room, [...peers.values()]);
      if (result.info) self.info = result.info;
      deliver(result.out);
      if (result.close) ws.close(1008, 'closed by server');
    });
    ws.on('close', () => {
      peers.delete(self.id);
      deliver(handleClose(self, [...peers.values()]).out);
      if (peers.size === 0) rooms.delete(room.key);
    });
    ws.on('error', () => ws.close());
  }

  return new Promise((resolve) => {
    server.listen(port, () => resolve({
      port: server.address().port,
      close: () => new Promise((done) => {
        for (const client of wss.clients) client.terminate();
        server.close(done);
      }),
    }));
  });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { port } = await startServer(Number(process.argv[2] ?? process.env.PORT ?? 8787));
  console.log(`connect: http://localhost:${port}`);
}
