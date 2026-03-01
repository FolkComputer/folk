# Status: Video Capability for Folk Computer

This document tracks the progress of adding high-performance video playback to the Folk Computer environment.

## 🏁 Accomplishments

### Phase 1: Fast-Path Texture API
- [x] **Ring-Buffered Staging:** Modified `GpuTextureBlock` in `builtin-programs/gpu/textures.folk` to support a ring of `NUM_STAGING_BUFFERS` (currently 3).
- [x] **Asynchronous Uploads:** Implemented `updateGpuTexture` using fences to ensure CPU-GPU synchronization without stalling the Tcl thread during frame uploads.
- [x] **Safe Cleanup:** Updated `freeGpuTexture` to correctly destroy per-texture staging buffers and fences.
- [x] **Verification:** Created and fixed `builtin-programs/test-video-texture.folk` to simulate a 60fps video source using a C-level fractal generator, confirming the texture path is bottleneck-free.

---

## 🚀 TODOs

### Phase 2: The `libav` (FFmpeg) Tcl Extension
- [ ] **Dependency Discovery:** Verify `libavcodec`, `libavformat`, and `libswscale` availability on target systems (Linux/macOS).
- [ ] **Decoder Core:** Implement `VideoPlayer` C struct to manage FFmpeg state (AVFormatContext, AVCodecContext).
- [ ] **Background Threading:** Implement a dedicated decoding thread for each video stream to prevent blocking the reactive Folk engine.
- [ ] **Frame Queue:** Create a thread-safe ring buffer for decoded `Image` frames ready for GPU upload.

### Phase 3: Folk Statement Integration
- [ ] **Reactive API:** Create `Wish to play video $path` and `When video $path is playing` statements.
- [ ] **Automatic Texture Management:** Implement logic to automatically allocate a GPU texture and handle its lifecycle when a video is requested.
- [ ] **Clock Synchronization:** Align frame polling with the display vblank or a system clock statement to ensure smooth playback.

### Phase 4: Audio & Lip-Sync
- [ ] **PCM Extraction:** Extract audio packets alongside video in the decoder thread.
- [ ] **Miniaudio Integration:** Use `builtin-programs/audio.folk` and `ma_data_source` to feed decoded PCM to the audio output.
- [ ] **Drift Correction:** Use Presentation Time Stamps (PTS) to adjust video polling rate, keeping audio and video in sync.

### Phase 5: UI & Controls
- [ ] **Video Primitive:** Add a high-level `draw video` primitive to `builtin-programs/draw/`.
- [ ] **Controls:** Implement seek, pause, and volume controls via Folk statements.
