(() => {
  const ws = new FolkWS(document.getElementById('connectionStatus'));
  // Keep model weights ready; inference runs only when a panel is clicked.
  ws.send('Wish to load SAM2');
  document.querySelectorAll('.camera-panel').forEach((panel, index) => {
    setupCamera(panel, `camera-sam2-request-${index}`);
  });

  function setupCamera(panel, requestKey) {
    const camera = panel.dataset.camera;
    const element = role => panel.querySelector(`[data-role="${role}"]`);
    const canvas = element('cameraCanvas');
    const ctx = canvas.getContext('2d');
    const outline = element('outline');
    const status = element('segmentStatus');
    const resume = element('resumeLive');
    let live = true;
    let busy = false;
    let generation = 0;
    let channel = null;
    let timeout = null;
    let frameTimer = null;

    function clearRequest() {
      clearTimeout(timeout);
      if (channel) { channel.stop(); channel = null; }
      ws.hold(requestKey, '');
    }

    function advanceCamera() {
      if (!live) return;
      const version = generation;
      const image = new Image();
      image.onload = () => {
        if (!live || version !== generation) return;
        canvas.width = image.naturalWidth;
        canvas.height = image.naturalHeight;
        ctx.drawImage(image, 0, 0);
        outline.setAttribute('viewBox', `0 0 ${canvas.width} ${canvas.height}`);
        status.textContent = 'Live — click an object to segment it.';
        frameTimer = setTimeout(advanceCamera, 0);
      };
      image.onerror = () => {
        if (!live || version !== generation) return;
        status.textContent = 'Waiting for a camera frame…';
        frameTimer = setTimeout(advanceCamera, 500);
      };
      image.src = '/camera-frame?' + new URLSearchParams({camera, uniq: Math.random()});
    }

    function showOutline(contours, x, y) {
      const ns = 'http://www.w3.org/2000/svg';
      outline.replaceChildren();
      for (const points of contours) {
        if (points.length < 3) continue;
        const polygon = document.createElementNS(ns, 'polygon');
        polygon.setAttribute('points', points.map(p => p.join(',')).join(' '));
        polygon.setAttribute('fill', 'none');
        polygon.setAttribute('stroke', '#00ff66');
        polygon.setAttribute('stroke-width', '2');
        polygon.setAttribute('vector-effect', 'non-scaling-stroke');
        outline.append(polygon);
      }
      const point = document.createElementNS(ns, 'circle');
      point.setAttribute('cx', x);
      point.setAttribute('cy', y);
      point.setAttribute('r', 4 * canvas.width / canvas.getBoundingClientRect().width);
      point.setAttribute('fill', '#ffcc00');
      outline.append(point);
    }

    canvas.addEventListener('click', async event => {
      if (busy || !canvas.width || !canvas.height || !canvas.hasAttribute('width')) return;
      live = false;
      busy = true;
      const version = ++generation;
      clearTimeout(frameTimer);
      const bounds = canvas.getBoundingClientRect();
      const x = Math.min(canvas.width - 1, Math.max(0, Math.floor((event.clientX - bounds.left) * canvas.width / bounds.width)));
      const y = Math.min(canvas.height - 1, Math.max(0, Math.floor((event.clientY - bounds.top) * canvas.height / bounds.height)));
      // Capture only the underlying image: previous outlines live in the SVG.
      const jpeg = canvas.toDataURL('image/jpeg', 0.95).split(',')[1];
      const request = (crypto.getRandomValues(new Uint32Array(1))[0] & 0x7fffffff) || 1;
      outline.replaceChildren();
      status.textContent = 'Segmenting… SAM2 may take a moment to load.';
      try {
        clearRequest();
        const subscription = await ws.watch(tcl`/any/ claims camera-sam2 request ${request} has result /json/`, {add: match => {
          if (version !== generation) return;
          try {
            const result = JSON.parse(match.json);
            if (result.error) throw new Error(result.error);
            if (result.width !== canvas.width || result.height !== canvas.height) throw new Error('Segmentation image size changed.');
            showOutline(result.contours, x, y);
            status.textContent = result.contours.length ? 'Segmented once. Click another point or resume live.' : 'No region found. Try another point or resume live.';
          } catch (error) {
            status.textContent = `Segmentation failed: ${error.message}`;
          } finally {
            busy = false;
            clearRequest();
          }
        }});
        if (version !== generation) { subscription.stop(); return; }
        channel = subscription;
        timeout = setTimeout(() => {
          if (version !== generation) return;
          ++generation;
          busy = false;
          status.textContent = 'Segmentation timed out. Check the SAM2 program logs, then click to retry.';
          clearRequest();
        }, 180000);
        await ws.hold(requestKey, tcl`Wish camera-sam2 request ${request} segments jpeg ${jpeg} at ${x} ${y}`);
      } catch (error) {
        if (version !== generation) return;
        busy = false;
        status.textContent = `Segmentation failed: ${error.message}`;
        clearRequest();
      }
    });

    resume.addEventListener('click', () => {
      ++generation;
      clearRequest();
      clearTimeout(frameTimer);
      busy = false;
      live = true;
      outline.replaceChildren();
      advanceCamera();
    });

    const auto = element('cameraAutoexposure');
    const slider = element('cameraExposureSlider');
    const number = element('cameraExposureNumber');
    const manual = element('manualExposure');
    function updateExposure(value, send = true) {
      auto.checked = value === 0;
      slider.disabled = number.disabled = auto.checked;
      manual.style.opacity = auto.checked ? 0.5 : 1;
      if (value !== 0) { slider.value = value / 100; number.value = value; }
      if (send) ws.hold('exposure ' + loadList(camera)[0], tcl`Wish camera ${loadList(camera)[0]} uses exposure time ${value} us`, 'builtin-programs/web/setup.folk', true);
    }
    slider.addEventListener('input', () => updateExposure(Math.round(Number(slider.value) * 100)));
    number.addEventListener('input', () => {
      const value = Number(number.value);
      if (Number.isFinite(value) && value >= 1000 && value <= 320000) updateExposure(value);
    });
    auto.addEventListener('change', () => updateExposure(auto.checked ? 0 : Number(number.value)));
    updateExposure(Number(panel.dataset.exposure), false);
    advanceCamera();
  }
})();
