(() => {
  const ws = new FolkWS(document.getElementById('connectionStatus'));
  // Keep model weights ready; inference runs only when a panel is clicked.
  ws.send('Wish to load SAM2');
  const stereoStatus = document.getElementById('stereoStatus');
  const stereoQuad = document.getElementById('stereoQuad');
  let stereoGeneration = 0;
  let stereoChannel = null;
  let stereoTimeout = null;
  const cameras = Array.from(document.querySelectorAll('.camera-panel'), (panel, index) =>
    setupCamera(panel, `camera-sam2-request-${index}`));

  function svgElement(parent, name, attributes, text) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', name);
    for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
    if (text !== undefined) node.textContent = text;
    parent.append(node);
    return node;
  }

  function drawQuad(parent, points, lengths, labelSize, numberCorners = false) {
    svgElement(parent, 'polygon', {points: points.map(p => p.join(',')).join(' '), fill: 'none',
      stroke: '#00ccff', 'stroke-width': 3, 'vector-effect': 'non-scaling-stroke'});
    const center = points.reduce((sum, p) => [sum[0] + p[0] / 4, sum[1] + p[1] / 4], [0, 0]);
    points.forEach((point, index) => {
      const next = points[(index + 1) % 4];
      const dx = next[0] - point[0], dy = next[1] - point[1];
      const edgeLength = Math.hypot(dx, dy);
      if (!edgeLength) return;
      // Fit short sides and put text outside the object, independent of winding.
      const fontSize = Math.min(labelSize, edgeLength / 4.5);
      const midpoint = [(point[0] + next[0]) / 2, (point[1] + next[1]) / 2];
      let nx = dy / edgeLength, ny = -dx / edgeLength;
      if (nx * (midpoint[0] - center[0]) + ny * (midpoint[1] - center[1]) < 0) {
        nx = -nx; ny = -ny;
      }
      const x = midpoint[0] + nx * labelSize * 1.2;
      const y = midpoint[1] + ny * labelSize * 1.2;
      let angle = Math.atan2(dy, dx) * 180 / Math.PI;
      if (angle > 90) angle -= 180;
      if (angle < -90) angle += 180;
      const style = {'font-size': fontSize, 'font-family': 'sans-serif', fill: 'white',
        stroke: 'black', 'stroke-width': fontSize / 8, 'paint-order': 'stroke',
        'text-anchor': 'middle', 'dominant-baseline': 'middle'};
      svgElement(parent, 'text', {...style, x, y, transform: `rotate(${angle} ${x} ${y})`},
        `${lengths[index].toFixed(3)} m`);
      if (numberCorners) {
        const vx = point[0] - center[0], vy = point[1] - center[1];
        const distance = Math.hypot(vx, vy) || 1;
        svgElement(parent, 'text', {...style, 'font-size': labelSize * 0.75,
          x: point[0] + vx / distance * labelSize, y: point[1] + vy / distance * labelSize}, String(index + 1));
      }
    });
  }

  function invalidateStereo() {
    ++stereoGeneration;
    clearTimeout(stereoTimeout);
    if (stereoChannel) { stereoChannel.stop(); stereoChannel = null; }
    ws.hold('camera-sam2-stereo', '');
    stereoQuad.replaceChildren();
    stereoStatus.textContent = 'Segment the same flat, four-sided surface in both cameras.';
    cameras.forEach(camera => camera.clearQuad());
  }

  async function reconstructStereo() {
    if (cameras.length !== 2 || cameras.some(camera => !camera.segment)) return;
    const version = stereoGeneration;
    const request = (crypto.getRandomValues(new Uint32Array(1))[0] & 0x7fffffff) || 1;
    stereoStatus.textContent = 'Finding corners and reconstructing the stereo quad…';
    try {
      const subscription = await ws.watch(tcl`/any/ claims camera-sam2 stereo request ${request} has result /json/`, {add: match => {
        if (version !== stereoGeneration) return;
        clearTimeout(stereoTimeout);
        try {
          const result = JSON.parse(match.json);
          if (result.error) throw new Error(result.error);
          cameras.forEach((camera, index) => camera.showQuad(result.cameraQuads[index], result.lengths));
          const xs = result.planeQuad.map(p => p[0]);
          const ys = result.planeQuad.map(p => p[1]);
          const minX = Math.min(...xs), minY = Math.min(...ys);
          const scale = Math.min(480 / Math.max(...xs.map(x => x - minX)), 200 / Math.max(...ys.map(y => y - minY)));
          const points = result.planeQuad.map(p => [60 + (p[0] - minX) * scale, 50 + (p[1] - minY) * scale]);
          stereoQuad.setAttribute('viewBox', '0 0 600 300');
          stereoQuad.replaceChildren();
          drawQuad(stereoQuad, points, result.lengths, 13, true);
          stereoStatus.textContent = `Quad projected. Side lengths are in meters; reprojection RMS ${result.reprojectionRms.toFixed(2)} px. ` +
            `Center in projector coordinates: ${result.center.map(x => x.toFixed(3)).join(', ')} m.`;
        } catch (error) {
          stereoStatus.textContent = `Stereo reconstruction failed: ${error.message}`;
        }
        if (stereoChannel) { stereoChannel.stop(); stereoChannel = null; }
        // Keep the request held: it owns the projected outline until either view changes.
      }});
      if (version !== stereoGeneration) { subscription.stop(); return; }
      stereoChannel = subscription;
      stereoTimeout = setTimeout(() => {
        if (version !== stereoGeneration) return;
        invalidateStereo();
        stereoStatus.textContent = 'Stereo reconstruction timed out. Segment again to retry.';
      }, 180000);
      await ws.hold('camera-sam2-stereo', tcl`Wish camera-sam2 stereo request ${request} reconstructs cameras ${cameras[0].camera} ${cameras[1].camera} segments ${JSON.stringify(cameras[0].segment)} ${JSON.stringify(cameras[1].segment)}`);
    } catch (error) {
      if (version !== stereoGeneration) return;
      invalidateStereo();
      stereoStatus.textContent = `Stereo reconstruction failed: ${error.message}`;
    }
  }

  function setupCamera(panel, requestKey) {
    const camera = panel.dataset.camera;
    const element = role => panel.querySelector(`[data-role="${role}"]`);
    const canvas = element('cameraCanvas');
    const outline = element('outline');
    const status = element('segmentStatus');
    const resume = element('resumeLive');
    const state = {camera, segment: null,
      clearQuad() { if (state.segment) showOutline(state.segment.contours); },
      showQuad(points, lengths) {
        state.clearQuad();
        drawQuad(outline, points, lengths, 10 * canvas.width / canvas.getBoundingClientRect().width);
      },
    };
    let promptPoints = [];
    let promptLabels = [];
    let frozenJpeg = null;
    let live = true;
    let busy = false;
    let generation = 0;
    let channel = null;
    let timeout = null;
    let frameTimer = null;
    let frameRequest = null;

    function clearRequest() {
      clearTimeout(timeout);
      if (channel) { channel.stop(); channel = null; }
      ws.hold(requestKey, '');
    }

    async function advanceCamera() {
      if (!live) return;
      if (document.hidden) { frameTimer = setTimeout(advanceCamera, 500); return; }
      const version = generation;
      const controller = new AbortController();
      frameRequest = controller;
      try {
        const drawn = await drawCameraFrame(canvas, camera, {signal: controller.signal,
          shouldDraw: () => live && version === generation && !document.hidden});
        if (!live || version !== generation) return;
        if (drawn) {
          outline.setAttribute('viewBox', `0 0 ${canvas.width} ${canvas.height}`);
          status.textContent = 'Live — click an object to segment it.';
        }
        frameTimer = setTimeout(advanceCamera, 100);
      } catch (error) {
        if (!live || version !== generation) return;
        status.textContent = 'Waiting for a camera frame…';
        frameTimer = setTimeout(advanceCamera, 500);
      } finally {
        if (frameRequest === controller) frameRequest = null;
      }
    }

    function showOutline(contours) {
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
      showPrompts();
    }

    function showPrompts() {
      promptPoints.forEach(([x, y], index) => {
        svgElement(outline, 'circle', {cx: x, cy: y,
          r: 4 * canvas.width / canvas.getBoundingClientRect().width,
          fill: promptLabels[index] ? '#ffcc00' : '#ff3333',
          stroke: 'white', 'stroke-width': 1, 'vector-effect': 'non-scaling-stroke'});
      });
    }

    async function promptSegment(event, label) {
      if (!label) event.preventDefault();
      if (busy || !canvas.width || !canvas.height || !canvas.hasAttribute('width')) return;
      if (!label && !promptPoints.length) {
        status.textContent = 'Left-click an object before adding negative points.';
        return;
      }
      state.segment = null;
      invalidateStereo();
      live = false;
      busy = true;
      const version = ++generation;
      clearTimeout(frameTimer);
      frameRequest?.abort();
      const bounds = canvas.getBoundingClientRect();
      const x = Math.min(canvas.width - 1, Math.max(0, Math.floor((event.clientX - bounds.left) * canvas.width / bounds.width)));
      const y = Math.min(canvas.height - 1, Math.max(0, Math.floor((event.clientY - bounds.top) * canvas.height / bounds.height)));
      // Capture only the underlying image: previous outlines live in the SVG.
      if (frozenJpeg === null) frozenJpeg = canvas.toDataURL('image/jpeg', 0.95).split(',')[1];
      promptPoints.push([x, y]);
      promptLabels.push(label);
      const request = (crypto.getRandomValues(new Uint32Array(1))[0] & 0x7fffffff) || 1;
      outline.replaceChildren();
      showPrompts();
      status.textContent = 'Segmenting… SAM2 may take a moment to load.';
      try {
        clearRequest();
        const subscription = await ws.watch(tcl`/any/ claims camera-sam2 request ${request} has result /json/`, {add: match => {
          if (version !== generation) return;
          try {
            const result = JSON.parse(match.json);
            if (result.error) throw new Error(result.error);
            if (result.width !== canvas.width || result.height !== canvas.height) throw new Error('Segmentation image size changed.');
            showOutline(result.contours);
            state.segment = result.contours.length ? result : null;
            reconstructStereo();
            status.textContent = result.contours.length ? 'Segmented. Left-click to include more; right-click to exclude. Resume live starts over.' : 'No region found. Try another point or resume live.';
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
        await ws.hold(requestKey, tcl`Wish camera-sam2 request ${request} segments jpeg ${frozenJpeg} with points ${promptPoints} labels ${promptLabels}`);
      } catch (error) {
        if (version !== generation) return;
        busy = false;
        status.textContent = `Segmentation failed: ${error.message}`;
        clearRequest();
      }
    }
    canvas.addEventListener('click', event => promptSegment(event, 1));
    canvas.addEventListener('contextmenu', event => promptSegment(event, 0));

    resume.addEventListener('click', () => {
      promptPoints = [];
      promptLabels = [];
      frozenJpeg = null;
      state.segment = null;
      invalidateStereo();
      ++generation;
      clearRequest();
      clearTimeout(frameTimer);
      frameRequest?.abort();
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
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) frameRequest?.abort();
    });
    window.addEventListener('pagehide', () => {
      live = false;
      ++generation;
      clearTimeout(frameTimer);
      clearTimeout(timeout);
      frameRequest?.abort();
    });
    updateExposure(Number(panel.dataset.exposure), false);
    advanceCamera();
    return state;
  }
})();
