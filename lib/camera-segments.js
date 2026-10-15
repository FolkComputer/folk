(() => {
  const ws = new FolkWS(document.getElementById('connectionStatus'));
  const auto = document.getElementById('autoUpdate');
  const opacity = document.getElementById('opacity');
  ws.send('Wish to load SAM2');
  const cameras = Array.from(document.querySelectorAll('.camera-panel'), (panel, index) => setup(panel, index));
  document.getElementById('refreshAll').addEventListener('click', () => cameras.forEach(camera => camera.refresh()));
  auto.addEventListener('change', () => cameras.forEach(camera => camera.schedule()));
  opacity.addEventListener('input', () => cameras.forEach(camera => camera.updateOpacity()));

  function setup(panel, index) {
    const element = role => panel.querySelector(`[data-role="${role}"]`);
    const canvas = element('frame');
    const overlay = element('overlay');
    const status = element('status');
    const button = element('refresh');
    const requestKey = `camera-segments-${index}`;
    let busy = false;
    let generation = 0;
    let channel = null;
    let timeout = null;
    let timer = null;
    let frameRequest = null;
    let stopped = false;

    function schedule() {
      clearTimeout(timer);
      if (!stopped && !document.hidden && auto.checked && !busy) timer = setTimeout(refresh, 1000);
    }
    function updateOpacity() { overlay.style.opacity = Number(opacity.value) / 100; }
    function clearRequest() {
      clearTimeout(timeout);
      frameRequest?.abort();
      if (channel) { channel.stop(); channel = null; }
      ws.hold(requestKey, '');
    }
    function finish(error) {
      clearRequest();
      busy = false;
      button.disabled = false;
      if (error) status.textContent = `Segmentation failed: ${error.message}`;
      schedule();
    }
    async function refresh() {
      if (busy || stopped) return;
      clearTimeout(timer);
      busy = true;
      button.disabled = true;
      const version = ++generation;
      status.textContent = 'Capturing frame…';
      timeout = setTimeout(() => {
        if (version !== generation) return;
        ++generation;
        finish(new Error('Timed out. Check the SAM2 program logs, then retry.'));
      }, 180000);
      try {
        frameRequest = new AbortController();
        const drawn = await drawCameraFrame(canvas, panel.dataset.camera, {signal: frameRequest.signal,
          shouldDraw: () => !stopped && version === generation});
        if (!drawn || version !== generation) return;
        // Only display an overlay on the exact snapshot that produced its masks.
        overlay.hidden = true;
        const jpeg = canvas.toDataURL('image/jpeg', .95).split(',')[1];
        const request = (crypto.getRandomValues(new Uint32Array(1))[0] & 0x7fffffff) || 1;
        status.textContent = 'Finding segments… SAM2 may take a moment to load.';
        const subscription = await ws.watch(tcl`/any/ claims camera-segments request ${request} has result /json/`, {add: async match => {
          if (version !== generation) return;
          try {
            const result = JSON.parse(match.json);
            if (result.error) throw new Error(result.error);
            if (result.width !== canvas.width || result.height !== canvas.height) throw new Error('Segmentation image size changed.');
            const drawn = await drawImageBlob(overlay, cameraOverlayBlob(result.overlay), {
              signal: frameRequest.signal, shouldDraw: () => !stopped && version === generation,
            });
            if (!drawn || version !== generation) return;
            overlay.hidden = false;
            status.textContent = `${result.segments.length} segments · ${result.elapsedSeconds.toFixed(1)} s`;
            finish();
          } catch (error) { if (version === generation) finish(error); }
        }});
        if (version !== generation) { subscription.stop(); return; }
        channel = subscription;
        await ws.hold(requestKey, tcl`Wish camera-segments request ${request} segments jpeg ${jpeg}`);
      } catch (error) {
        if (version === generation) finish(error);
      }
    }
    window.addEventListener('pagehide', () => {
      stopped = true;
      ++generation;
      clearTimeout(timer);
      clearTimeout(timeout);
      frameRequest?.abort();
    });
    document.addEventListener('visibilitychange', schedule);
    button.addEventListener('click', refresh);
    updateOpacity();
    refresh();
    return {refresh, schedule, updateOpacity};
  }
})();
