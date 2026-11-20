// One WebRTC connection to one peer.
//
// Between browsers this uses the "perfect negotiation" pattern, so
// either side can add a data channel or a media stream at any time.
// A Folk machine only ever answers, which the same code handles.
//
// Events: 'state' (detail: connection state), 'channel' (detail:
// RTCDataChannel opened by the other side), 'streams' (the set of
// incoming media streams changed).

export class Link extends EventTarget {
  constructor({ peerId, polite, send, iceServers = [] }) {
    super();
    this.peerId = peerId;
    this.polite = polite;
    this.send = send;
    this.makingOffer = false;
    this.ignoreOffer = false;
    this.pendingCandidates = [];
    this.remoteStreams = new Map();
    this.shared = new Map(); // what ('screen'|'camera'|'mic') -> {stream, senders}

    // With no ICE servers, the two ends can only find each other if
    // they can reach each other's local addresses: that is, if they
    // are really on the same network.
    const pc = this.pc = new RTCPeerConnection({ iceServers });

    pc.addEventListener('negotiationneeded', async () => {
      try {
        this.makingOffer = true;
        await pc.setLocalDescription();
        this.send({ description: pc.localDescription.toJSON() });
      } catch (err) {
        console.error('link: negotiation failed', err);
      } finally {
        this.makingOffer = false;
      }
    });
    pc.addEventListener('icecandidate', ({ candidate }) => {
      if (candidate) this.send({ candidate: candidate.toJSON() });
    });
    pc.addEventListener('connectionstatechange', () => {
      this.dispatchEvent(new CustomEvent('state', { detail: pc.connectionState }));
    });
    pc.addEventListener('datachannel', ({ channel }) => {
      this.dispatchEvent(new CustomEvent('channel', { detail: channel }));
    });
    pc.addEventListener('track', ({ track, streams }) => {
      for (const stream of streams) {
        this.remoteStreams.set(stream.id, stream);
        stream.addEventListener('removetrack', () => {
          if (stream.getTracks().length === 0) {
            this.remoteStreams.delete(stream.id);
            this.dispatchEvent(new CustomEvent('streams'));
          }
        });
      }
      this.dispatchEvent(new CustomEvent('streams'));
    });
  }

  get state() { return this.pc.connectionState; }

  async onSignal({ description, candidate }) {
    const pc = this.pc;
    try {
      if (description) {
        const collision = description.type === 'offer' &&
          (this.makingOffer || pc.signalingState !== 'stable');
        this.ignoreOffer = !this.polite && collision;
        if (this.ignoreOffer) return;

        await pc.setRemoteDescription(description);
        for (const c of this.pendingCandidates.splice(0)) await pc.addIceCandidate(c);
        if (description.type === 'offer') {
          await pc.setLocalDescription();
          this.send({ description: pc.localDescription.toJSON() });
        }
      } else if (candidate) {
        if (!pc.remoteDescription) {
          this.pendingCandidates.push(candidate);
          return;
        }
        try {
          await pc.addIceCandidate(candidate);
        } catch (err) {
          if (!this.ignoreOffer) throw err;
        }
      }
    } catch (err) {
      console.error('link: bad signal', err);
    }
  }

  channel(label, options) {
    return this.pc.createDataChannel(label, options);
  }

  // Share a MediaStream under a name; sharing again under the same
  // name replaces it. Tracks that end on their own (the user pressed
  // the browser's "stop sharing") un-share themselves.
  share(what, stream) {
    this.unshare(what);
    const senders = stream.getTracks().map((track) => {
      track.addEventListener('ended', () => {
        this.unshare(what);
        this.dispatchEvent(new CustomEvent('shared'));
      });
      return this.pc.addTrack(track, stream);
    });
    this.shared.set(what, { stream, senders });
  }

  unshare(what) {
    const entry = this.shared.get(what);
    if (!entry) return;
    this.shared.delete(what);
    for (const sender of entry.senders) {
      try { this.pc.removeTrack(sender); } catch {}
    }
    for (const track of entry.stream.getTracks()) track.stop();
  }

  close() {
    for (const what of [...this.shared.keys()]) this.unshare(what);
    this.pc.close();
    this.dispatchEvent(new CustomEvent('state', { detail: 'closed' }));
  }
}
