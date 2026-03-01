# Status: Video Capability for Folk Computer

This document tracks the progress of adding high-performance video playback to the Folk Computer environment.

## 🏁 Accomplishments

### Phase 1: Fast-Path Texture API
- [x] **Ring-Buffered Staging:** Modified `GpuTextureBlock` in `builtin-programs/gpu/textures.folk` to support a ring of `NUM_STAGING_BUFFERS` (currently 3).
- [x] **Asynchronous Uploads:** Implemented `updateGpuTexture` using fences to ensure CPU-GPU synchronization without stalling the Tcl thread during frame uploads.
- [x] **Safe Cleanup:** Updated `freeGpuTexture` to correctly destroy per-texture staging buffers and fences.
- [x] **Verification:** Created and fixed `test/video-texture.folk` to simulate a 60fps video source using a C-level fractal generator, confirming the texture path is bottleneck-free.

### Phase 2: The `libav` (FFmpeg) Tcl Extension
- [x] **Dependency Discovery:** Verified `libavcodec` and friends on Darwin via Homebrew.
- [x] **Decoder Core:** Implemented `VideoPlayer` C struct to manage FFmpeg state in `builtin-programs/video/video-lib.folk`.
- [x] **Background Threading:** Implemented a dedicated decoding thread `decoderLoop` for each video stream.
- [x] **Frame Queue:** Created a thread-safe ring buffer for decoded RGBA `Image` frames.

### Phase 3: Folk Statement Integration
- [x] **Reactive API:** Implemented `Wish to play video $path` in `builtin-programs/video/video.folk`.
- [x] **Automatic Texture Management:** Handled texture allocation and destruction via `Claim` destructors.
- [x] **Rendering Loop:** Integrated a polling mechanism that automatically updates the GPU texture whenever a new frame is decoded.

### Phase 4: Audio & Lip-Sync
- [x] **PCM Extraction:** The decoder now extracts audio packets and converts them to float32 PCM using `libswresample`.
- [x] **Miniaudio Integration:** Implemented a custom `ma_data_source` in `video-lib.folk` that feeds decoded audio samples directly into the Folk audio engine.
- [ ] **Drift Correction:** (In Progress) Need to implement clock synchronization using PTS to ensure audio and video don't drift.

---

## 🛠 Technical Hurdles & Confusion

### 1. Environment & Dependencies
- **Broken FFmpeg:** The host `ffmpeg` binary is currently broken (`libvpx` dependency error), making it difficult to generate a local `test.mp4` for verification.
- **Headless Execution:** Running `./folk` headlessly for testing requires a specific structure (`Assert! when we are on { ... }`) to ensure statements are processed correctly by the reactive engine.

### 2. Folk Syntax & Semantic Nuances
- **Say vs. When:** Enountered "Creating Say without parent match" warnings. This occurs when a top-level `When` or `Wish` is interpreted as a statement to be asserted rather than a reactive rule to be matched.
- **Clause Joining:** There is some ambiguity in the project's preferred style for multi-clause `When` blocks (using `& \` vs. `\`).
- **Headless Lifecycle:** Determining the exact moment a C-compiled library is "ready" to be queried via `When` in a standalone script has proven tricky.

---

## 🚀 TODOs

