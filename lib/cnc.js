(() => {
  const ws = new FolkWS(document.getElementById('connectionStatus'));
  const bedStatus = document.getElementById('bedStatus');
  ws.watchCollected('/any/ claims CNC bed reconstruction is /json/', matches => {
    const results = matches.map(match => JSON.parse(match.json));
    const result = results.find(result => !result.waiting) || results[0];
    if (!result) { bedStatus.textContent = 'Select four corners in each camera.'; return; }
    if (result.waiting) bedStatus.textContent = result.waiting;
    else if (result.error) bedStatus.textContent = `Reconstruction failed: ${result.error}`;
    else bedStatus.textContent = `Bed reconstructed and projected green. Reprojection RMS: ${result.reprojectionRms.toFixed(2)} px.`;
  });
  document.querySelectorAll('.camera-panel').forEach(setupCamera);

  function setupCamera(panel) {
    const camera = panel.dataset.camera;
    const element = role => panel.querySelector(`[data-role="${role}"]`);
    const canvas = element('frame');
    const overlay = element('corners');
    const status = element('status');
    const undo = element('undo');
    let selection = JSON.parse(panel.dataset.saved);
    let points = selection ? selection.points : [];
    let width = selection?.width || 0, height = selection?.height || 0;
    let dirty = false, saving = false, live = true, stopped = false;
    let generation = 0, frameTimer = null, frameRequest = null;

    function message() {
      undo.disabled = !points.length || saving;
      if (saving) status.textContent = 'Saving four corners…';
      else if (points.length === 4) status.textContent = 'Four corners saved. Resume live to inspect, or clear/redraw to change them.';
      else status.textContent = `Click corner ${points.length + 1} of 4${points.length ? ' — follow the bed perimeter.' : ' — start at the same physical corner in both views.'}`;
    }
    function svg(name, attributes, text) {
      const node = document.createElementNS('http://www.w3.org/2000/svg', name);
      for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
      if (text !== undefined) node.textContent = text;
      overlay.append(node);
    }
    function render() {
      overlay.replaceChildren();
      overlay.setAttribute('viewBox', `0 0 ${width || canvas.width || 300} ${height || canvas.height || 150}`);
      if (!points.length) return;
      svg(points.length === 4 ? 'polygon' : 'polyline', {
        points: points.map(p => p.join(',')).join(' '), fill: points.length === 4 ? '#00ff0018' : 'none',
        stroke: '#00ff66', 'stroke-width': 2, 'vector-effect': 'non-scaling-stroke',
      });
      const scale = (width || canvas.width) / canvas.getBoundingClientRect().width;
      points.forEach(([x, y], index) => {
        svg('circle', {cx:x, cy:y, r:4*scale, fill:'#ffcc00'});
        svg('text', {x:x+8*scale, y:y-8*scale, fill:'white', stroke:'black',
          'stroke-width':2*scale, 'paint-order':'stroke', 'font-size':14*scale}, String(index+1));
      });
    }
    ws.watchCollected(tcl`cnc claims camera ${camera} has CNC bed corners /points/ with width /width/ height /height/`, matches => {
      if (matches.length !== 1) {
        if (!dirty && !saving) { points=[]; selection=null; width=height=0; render(); message(); }
        return;
      }
      const match=matches[0];
      const saved={points:loadList(match.points).map(p=>loadList(p).map(Number)), width:Number(match.width), height:Number(match.height)};
      if (saving && JSON.stringify(saved.points) === JSON.stringify(points) && saved.width === width && saved.height === height) {
        saving=false; dirty=false; selection=saved;
      } else if (!dirty && !saving) {
        selection=saved; points=saved.points; width=saved.width; height=saved.height;
      }
      render(); message();
    });

    async function advance() {
      if (!live || stopped) return;
      if (document.hidden) { frameTimer=setTimeout(advance,500); return; }
      const version=generation;
      const controller=new AbortController();frameRequest=controller;
      try {
        const drawn=await drawCameraFrame(canvas,camera,{signal:controller.signal,
          shouldDraw:()=>live && !stopped && version===generation && !document.hidden});
        if (!live || stopped || version!==generation) return;
        if (drawn) { render(); message(); }
        frameTimer=setTimeout(advance,100);
      } catch(error) {
        if (!live || stopped || version!==generation) return;
        status.textContent=`Waiting for camera: ${error.message}`;
        frameTimer=setTimeout(advance,500);
      } finally { if (frameRequest===controller) frameRequest=null; }
    }
    function resume() {
      ++generation;clearTimeout(frameTimer);frameRequest?.abort();
      live=true;advance();
    }
    async function clearSaved() {
      selection=null; saving=false; dirty=true;
      await ws.run(tcl`Hold! -save -on cnc -key ${camera} {}`);
    }
    canvas.addEventListener('click',async event=>{
      if (points.length===4 || saving || !canvas.hasAttribute('width')) return;
      live=false;++generation;clearTimeout(frameTimer);frameRequest?.abort();
      if (!points.length) { width=canvas.width;height=canvas.height; }
      const bounds=canvas.getBoundingClientRect();
      const x=Math.max(0,Math.min(width-1,(event.clientX-bounds.left)*width/bounds.width));
      const y=Math.max(0,Math.min(height-1,(event.clientY-bounds.top)*height/bounds.height));
      dirty=true;points.push([x,y]);render();message();
      if (points.length===4) {
        saving=true;message();
        try {
          // A single saved Hold per camera, containing the whole quad.
          await ws.run(tcl`Hold! -save -on cnc -key ${camera} -- cnc claims camera ${camera} has CNC bed corners ${points} with width ${width} height ${height}`);
        } catch(error) { saving=false;status.textContent=`Save failed: ${error.message}`; }
      }
    });
    undo.addEventListener('click',async()=>{
      if (!points.length || saving) return;
      try { await clearSaved();points.pop();render();message(); }
      catch(error) { status.textContent=`Could not clear saved corners: ${error.message}`; }
    });
    element('reset').addEventListener('click',async()=>{
      try { await clearSaved();points=[];width=height=0;render();message();resume(); }
      catch(error) { status.textContent=`Could not clear saved corners: ${error.message}`; }
    });
    element('resume').addEventListener('click',resume);
    document.addEventListener('visibilitychange',()=>{if(document.hidden)frameRequest?.abort();});
    window.addEventListener('pagehide',()=>{
      stopped=true;++generation;clearTimeout(frameTimer);frameRequest?.abort();
    });
    message();advance();
  }
})();
