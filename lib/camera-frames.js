// Camera snapshots are transient. Do not create a distinct cached image URL for
// every frame, and explicitly release each decoded image after drawing it.
async function drawImageBlob(canvas, blob, {signal, shouldDraw = () => true} = {}) {
  const bitmap = await createImageBitmap(blob);
  try {
    if (signal?.aborted || !shouldDraw()) return false;
    // Assigning either dimension reallocates/clears the canvas backing buffer.
    if (canvas.width !== bitmap.width) canvas.width = bitmap.width;
    if (canvas.height !== bitmap.height) canvas.height = bitmap.height;
    const context = canvas.getContext('2d');
    context.clearRect(0, 0, canvas.width, canvas.height);
    context.drawImage(bitmap, 0, 0);
    return true;
  } finally {
    bitmap.close();
  }
}

async function drawCameraFrame(canvas, camera, options = {}) {
  const response = await fetch('/camera-frame?' + new URLSearchParams({camera}), {
    cache: 'no-store', signal: options.signal,
  });
  if (!response.ok) throw new Error(`Camera frame failed (${response.status})`);
  return drawImageBlob(canvas, await response.blob(), options);
}

function cameraOverlayBlob(encoded) {
  const bytes = atob(encoded);
  return new Blob([Uint8Array.from(bytes, c => c.charCodeAt(0))], {type: 'image/png'});
}

if (typeof module !== 'undefined') module.exports = {drawImageBlob, drawCameraFrame, cameraOverlayBlob};
