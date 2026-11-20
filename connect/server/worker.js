// Cloudflare Worker entry point for the Folk connect server.
//
// Static files (web/) are served by the assets binding. The only
// dynamic route is /ws, which is handed to one Durable Object per
// room. The Durable Object uses WebSocket hibernation, so an idle
// room (a Folk machine waiting for someone to show up) costs nothing:
// all per-peer state lives in each socket's attachment.

import { handleMessage, handleClose, roomFor, newPeerId } from './room.js';

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/ws') return env.ASSETS.fetch(request);

    if (request.headers.get('Upgrade') !== 'websocket') {
      return new Response('Expected a WebSocket upgrade', { status: 426 });
    }
    const room = await roomFor({
      room: url.searchParams.get('room'),
      ip: request.headers.get('CF-Connecting-IP'),
    });

    const headers = new Headers(request.headers);
    headers.set('X-Room-Kind', room.kind);
    headers.set('X-Room-Label', room.label);
    const stub = env.ROOMS.get(env.ROOMS.idFromName(room.key));
    return stub.fetch(new Request(request, { headers }));
  },
};

export class Room {
  constructor(ctx, env) {
    this.ctx = ctx;
    // Answer keep-alive pings without waking the object up.
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(
      '{"type":"ping"}', '{"type":"pong"}'));
  }

  async fetch(request) {
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({
      id: newPeerId(),
      info: null,
      room: {
        kind: request.headers.get('X-Room-Kind'),
        label: request.headers.get('X-Room-Label'),
      },
    });
    return new Response(null, { status: 101, webSocket: client });
  }

  sockets(except = null) {
    return this.ctx.getWebSockets()
      .filter((ws) => ws !== except)
      .map((ws) => ({ ws, ...ws.deserializeAttachment() }));
  }

  deliver(out, sockets) {
    for (const { to, msg } of out) {
      const target = sockets.find((s) => s.id === to);
      try { target?.ws.send(JSON.stringify(msg)); } catch {}
    }
  }

  webSocketMessage(ws, raw) {
    const self = ws.deserializeAttachment();
    const sockets = this.sockets();
    const result = handleMessage(self, raw, self.room, sockets);
    if (result.info) ws.serializeAttachment({ ...self, info: result.info });
    this.deliver(result.out, sockets);
    if (result.close) ws.close(1008, 'closed by server');
  }

  webSocketClose(ws) { this.leave(ws); }
  webSocketError(ws) { this.leave(ws); }

  leave(ws) {
    const self = ws.deserializeAttachment();
    const sockets = this.sockets(ws);
    this.deliver(handleClose(self, sockets).out, sockets);
    try { ws.close(); } catch {}
  }
}
