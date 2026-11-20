// Connection to the signaling server: who else is in the room, and a
// way to pass WebRTC offers/answers/candidates to one of them.
//
// Events: 'up' (detail: welcome message), 'down', 'peer-joined',
// 'peer-left', 'signal', 'server-error'.

export class Signal extends EventTarget {
  constructor({ url, hello }) {
    super();
    this.url = url;
    this.hello = hello;
    this.id = null;
    this.closed = false;
    this.connect();
  }

  connect() {
    if (this.closed) return;
    const ws = this.ws = new WebSocket(this.url);
    let keepAlive = null;

    ws.addEventListener('open', () => {
      ws.send(JSON.stringify({ type: 'hello', ...this.hello }));
      keepAlive = setInterval(() => ws.send('{"type":"ping"}'), 25000);
    });
    ws.addEventListener('message', (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      if (msg.type === 'pong') return;
      if (msg.type === 'welcome') {
        this.id = msg.id;
        this.dispatchEvent(new CustomEvent('up', { detail: msg }));
      } else if (msg.type === 'error') {
        this.dispatchEvent(new CustomEvent('server-error', { detail: msg }));
      } else {
        this.dispatchEvent(new CustomEvent(msg.type, { detail: msg }));
      }
    });
    ws.addEventListener('close', () => {
      clearInterval(keepAlive);
      if (this.ws !== ws) return;
      this.id = null;
      this.dispatchEvent(new CustomEvent('down'));
      setTimeout(() => this.connect(), 1500);
    });
    ws.addEventListener('error', () => ws.close());
  }

  send(to, data) {
    if (this.ws.readyState !== WebSocket.OPEN) return;
    this.ws.send(JSON.stringify({ type: 'signal', to, data }));
  }

  // Changing how we present ourselves (name or kind) means rejoining,
  // because the room announced us under the old description.
  rejoin(hello) {
    this.hello = hello;
    this.ws.close();
  }

  close() {
    this.closed = true;
    this.ws.close();
  }
}
