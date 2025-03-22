# video-utils.tcl
# Video Utilities for Folk - Streamlined version
# Handles video decoding, frame extraction, and caching

namespace eval VideoState {
    variable sources; array set sources {}
    variable metadata; array set metadata {}
    variable debug 1
    
    proc log {level message} {
        variable debug
        if {$level <= $debug} {
            puts "\[VIDEO:[lindex {ERR WARN INFO DBG} $level]\] $message"
        }
    }
    
    proc registerSource {thing source} {
        variable sources
        set sources($thing) $source
        log 0 "Playing video: $source"
    }
    
    proc getSource {thing} {
        variable sources
        if {[info exists sources($thing)]} {return $sources($thing)}
        return ""
    }
    
    proc updateMetadata {source fps duration frames} {
        variable metadata
        if {![info exists metadata($source)]} {set metadata($source) [dict create]}
        dict set metadata($source) fps $fps
        dict set metadata($source) duration $duration
        dict set metadata($source) totalFrames $frames
        log 0 "Video metadata: $source - ${fps}fps, ${duration}s, $frames frames"
    }
    
    proc getMetadata {source} {
        variable metadata
        if {[info exists metadata($source)]} {return $metadata($source)}
        return [dict create fps 30.0 duration 1.0 totalFrames 30]
    }
    
    proc setStartTime {thing time} {
        variable metadata
        if {![info exists metadata($thing)]} {set metadata($thing) [dict create]}
        dict set metadata($thing) startTime $time
        log 0 "Set start time for $thing to $time"
    }
    
    proc getStartTime {thing {default 0}} {
        variable metadata
        if {[info exists metadata($thing)] && [dict exists $metadata($thing) startTime]} {
            return [dict get $metadata($thing) startTime]
        }
        return $default
    }
    
    # Calculate frame number with proper looping
    proc getFrameNumber {thing time} {
        set startTime [getStartTime $thing]
        if {$startTime == 0} {return 1}
        
        set relativeTime [expr {$time - $startTime}]
        if {$relativeTime < 0} {return 1}
        
        set source [getSource $thing]
        if {$source eq ""} {return 1}
        
        set sourceInfo [getMetadata $source]
        set fps [dict get $sourceInfo fps]
        set duration [dict get $sourceInfo duration]
        set totalFrames [dict get $sourceInfo totalFrames]
        
        # Proper looping logic
        if {$duration > 0} {
            set loopCount [expr {int($relativeTime / $duration)}]
            set loopPosition [expr {fmod($relativeTime, $duration)}]
            
            # Log loop transitions (only once per loop)
            if {$loopPosition < 0.05 && $loopCount > 0} {
                variable lastLoopCount
                if {![info exists lastLoopCount($thing)] || $lastLoopCount($thing) != $loopCount} {
                    log 0 "Loop transition - loop #$loopCount (time=$time)"
                    set lastLoopCount($thing) $loopCount
                }
            }
        }
        
        # Calculate frame based on position in current loop
        set frameNum [expr {int(fmod($relativeTime, $duration) * $fps) + 1}]
        
        # Ensure frame is in valid range
        if {$frameNum > $totalFrames} {set frameNum $totalFrames}
        if {$frameNum < 1} {set frameNum 1}
        
        return $frameNum
    }
    
    # Performance tracking
    variable stats
    array set stats {frameCount 0 cacheHits 0}
    
    proc recordStats {isCache} {
        variable stats
        incr stats(frameCount)
        if {$isCache} {incr stats(cacheHits)}
        
        # Log every 20 frames
        if {$stats(frameCount) % 20 == 0} {
            set hitRate [expr {$stats(frameCount) > 0 ? 
                              double($stats(cacheHits)) / $stats(frameCount) * 100.0 : 0}]
            log 0 [format "PERF: %d frames, %.1f%% cache hit rate" \
                   $stats(frameCount) $hitRate]
        }
    }
}

namespace eval video {
    set cc [c create]
    ::defineImageType $cc
    $cc cflags -lavcodec -lavformat -lavutil -lswscale -Wno-deprecated-declarations

    # Load libraries
    if {$tcl_platform(os) eq "Darwin"} {
        c loadlib "/opt/homebrew/lib/libavutil.dylib"
        c loadlib "/opt/homebrew/lib/libavcodec.dylib"
        c loadlib "/opt/homebrew/lib/libavformat.dylib"
        c loadlib "/opt/homebrew/lib/swscale.dylib"
    } else {
        c loadlib "/usr/lib/x86_64-linux-gnu/libavutil.so"
        c loadlib "/usr/lib/x86_64-linux-gnu/libavcodec.so"
        c loadlib "/usr/lib/x86_64-linux-gnu/libavformat.so"
        c loadlib "/usr/lib/x86_64-linux-gnu/libswscale.so"
    }
    
    $cc include <stdio.h>
    $cc include <stdlib.h>
    $cc include <string.h>
    $cc include <libavutil/imgutils.h>
    $cc include <libavcodec/avcodec.h>
    $cc include <libavformat/avformat.h>
    $cc include <libswscale/swscale.h>

    $cc import ::Heap::cc folkHeapAlloc as folkHeapAlloc
    $cc import ::Heap::cc folkHeapFree as folkHeapFree

    $cc proc init {} void {}
    
    # Simple logging function
    $cc proc cLog {Tcl_Interp* interp char* msg} void {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "VideoState::log 0 {%s}", msg);
        Tcl_Eval(interp, cmd);
    }
    
    # Debug image generator
    $cc proc generateDebugImage {} image_t {
        image_t ret;
        ret.width = 64;
        ret.height = 64;
        ret.components = 4;
        ret.bytesPerRow = ret.width * ret.components;
        ret.data = folkHeapAlloc(ret.bytesPerRow * ret.height);
        
        if (ret.data) {
            // Fill with magenta pattern
            for (int y = 0; y < ret.height; y++) {
                for (int x = 0; x < ret.width; x++) {
                    int offset = y * ret.bytesPerRow + x * ret.components;
                    ret.data[offset] = 255;     // R
                    ret.data[offset + 1] = 0;   // G
                    ret.data[offset + 2] = 255; // B
                    ret.data[offset + 3] = 255; // A
                }
            }
        }
        return ret;
    }
    
    # Cache and video context implementation
    $cc code {
        // --- Cache structures ---
        typedef struct {
            image_t frame;
            int frameNumber;
            char path[256];
            int valid;
        } CacheEntry;
        
        // --- Video context for keeping files open ---
        typedef struct {
            AVFormatContext *fmt_ctx;
            AVCodecContext *codec_ctx;
            int video_stream;
            int lastFrameDecoded;
            int isActive;
            char path[256];
        } VideoContext;
        
        #define CACHE_SIZE 8
        #define MAX_CONTEXTS 2
        
        CacheEntry frameCache[CACHE_SIZE];
        VideoContext contexts[MAX_CONTEXTS];
        int nextCacheSlot = 0;
        int initialized = 0;
        
        // Initialize cache and contexts
        void initializeCache() {
            if (initialized) return;
            
            // Init cache
            for (int i = 0; i < CACHE_SIZE; i++) {
                frameCache[i].frame.data = NULL;
                frameCache[i].valid = 0;
            }
            
            // Init contexts
            for (int i = 0; i < MAX_CONTEXTS; i++) {
                contexts[i].fmt_ctx = NULL;
                contexts[i].codec_ctx = NULL;
                contexts[i].isActive = 0;
                contexts[i].path[0] = '\0';
            }
            
            initialized = 1;
        }
        
        // Find a context for a path
        int findContext(const char* path) {
            for (int i = 0; i < MAX_CONTEXTS; i++) {
                if (contexts[i].isActive && 
                    strcmp(contexts[i].path, path) == 0) {
                    return i;
                }
            }
            return -1;
        }
        
        // Find or create a context slot
        int getContextSlot() {
            // First try to find an empty slot
            for (int i = 0; i < MAX_CONTEXTS; i++) {
                if (!contexts[i].isActive) {
                    return i;
                }
            }
            
            // If all are used, replace the first one
            return 0;
        }
        
        // Close a context and free resources
        void closeContext(int idx) {
            if (idx < 0 || idx >= MAX_CONTEXTS || !contexts[idx].isActive)
                return;
                
            if (contexts[idx].codec_ctx)
                avcodec_free_context(&contexts[idx].codec_ctx);
            if (contexts[idx].fmt_ctx)
                avformat_close_input(&contexts[idx].fmt_ctx);
                
            contexts[idx].isActive = 0;
            contexts[idx].path[0] = '\0';
        }
        
        // Free all resources
        void cleanupAll() {
            // Free cache frames
            for (int i = 0; i < CACHE_SIZE; i++) {
                if (frameCache[i].frame.data) {
                    folkHeapFree(frameCache[i].frame.data);
                    frameCache[i].frame.data = NULL;
                    frameCache[i].valid = 0;
                }
            }
            
            // Close all contexts
            for (int i = 0; i < MAX_CONTEXTS; i++) {
                closeContext(i);
            }
        }
        
        // Check if frame is magenta debug frame
        int isMagenta(image_t image) {
            if (!image.data || image.width < 10) return 1;
            
            // Check center pixel
            int x = image.width / 2;
            int y = image.height / 2;
            int offset = y * image.bytesPerRow + x * image.components;
            
            return (image.data[offset] > 200 && 
                    image.data[offset+1] < 50 && 
                    image.data[offset+2] > 200);
        }
        
        // Get a cached frame
        int getCachedFrame(const char* path, int frameNum, image_t* outImage) {
            initializeCache();
            
            // Find in cache
            for (int i = 0; i < CACHE_SIZE; i++) {
                if (frameCache[i].valid && 
                    frameCache[i].frameNumber == frameNum &&
                    strcmp(frameCache[i].path, path) == 0) {
                    *outImage = frameCache[i].frame;
                    return 1;
                }
            }
            
            return 0;
        }
        
        // Store a frame in cache
        void cacheFrame(const char* path, int frameNum, image_t image) {
            initializeCache();
            
            // Don't cache debug frames
            if (isMagenta(image)) return;
            
            // Check if already cached
            for (int i = 0; i < CACHE_SIZE; i++) {
                if (frameCache[i].valid && 
                    frameCache[i].frameNumber == frameNum &&
                    strcmp(frameCache[i].path, path) == 0) {
                    return;
                }
            }
            
            // Free old frame if present
            if (frameCache[nextCacheSlot].frame.data) {
                folkHeapFree(frameCache[nextCacheSlot].frame.data);
            }
            
            // Store new frame
            strncpy(frameCache[nextCacheSlot].path, path, 255);
            frameCache[nextCacheSlot].frameNumber = frameNum;
            frameCache[nextCacheSlot].frame = image;
            frameCache[nextCacheSlot].valid = 1;
            
            // Move to next slot
            nextCacheSlot = (nextCacheSlot + 1) % CACHE_SIZE;
        }
        
        // Open or get existing video context
        int openVideoContext(const char* path, int* isNew) {
            initializeCache();
            
            // Check if already open
            int idx = findContext(path);
            if (idx >= 0) {
                *isNew = 0;
                return idx;
            }
            
            // Get a slot
            idx = getContextSlot();
            *isNew = 1;
            
            // Close existing context if needed
            closeContext(idx);
            
            // Open the file
            AVFormatContext *fmt_ctx = NULL;
            if (avformat_open_input(&fmt_ctx, path, NULL, NULL) != 0) {
                return -1;
            }
            
            if (avformat_find_stream_info(fmt_ctx, NULL) < 0) {
                avformat_close_input(&fmt_ctx);
                return -1;
            }
            
            // Find video stream
            int video_stream = -1;
            for (int i = 0; i < fmt_ctx->nb_streams; i++) {
                if (fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
                    video_stream = i;
                    break;
                }
            }
            
            if (video_stream < 0) {
                avformat_close_input(&fmt_ctx);
                return -1;
            }
            
            // Setup decoder
            const AVCodec *codec = avcodec_find_decoder(
                fmt_ctx->streams[video_stream]->codecpar->codec_id);
                
            AVCodecContext *codec_ctx = avcodec_alloc_context3(codec);
            if (!codec_ctx) {
                avformat_close_input(&fmt_ctx);
                return -1;
            }
            
            if (avcodec_parameters_to_context(codec_ctx, 
                fmt_ctx->streams[video_stream]->codecpar) < 0 ||
                avcodec_open2(codec_ctx, codec, NULL) < 0) {
                avcodec_free_context(&codec_ctx);
                avformat_close_input(&fmt_ctx);
                return -1;
            }
            
            // Store context
            contexts[idx].fmt_ctx = fmt_ctx;
            contexts[idx].codec_ctx = codec_ctx;
            contexts[idx].video_stream = video_stream;
            contexts[idx].lastFrameDecoded = -1;
            contexts[idx].isActive = 1;
            strncpy(contexts[idx].path, path, 255);
            
            return idx;
        }
    }
    
    # Video metadata analyzer
    $cc proc analyzeVideo {Tcl_Interp* interp char* videoPath} void {
        double fps = 30.0;
        double duration = 1.0;
        int total_frames = 30;
        
        // Open video context
        int isNew = 0;
        int contextIdx = openVideoContext(videoPath, &isNew);
        
        if (contextIdx >= 0) {
            // Get video info
            AVFormatContext* fmt_ctx = contexts[contextIdx].fmt_ctx;
            int video_stream = contexts[contextIdx].video_stream;
            
            fps = av_q2d(fmt_ctx->streams[video_stream]->avg_frame_rate);
            duration = fmt_ctx->duration / (double)AV_TIME_BASE;
            total_frames = fmt_ctx->streams[video_stream]->nb_frames;
            
            if (total_frames <= 0) {
                total_frames = (int)(duration * fps);
            }
            
            // Ensure valid values
            if (fps <= 0) fps = 30.0;
            if (duration <= 0) duration = 1.0;
            if (total_frames <= 0) total_frames = 30;
            
            // Log video details
            char log_msg[256];
            snprintf(log_msg, sizeof(log_msg), 
                    "Opened video: %dx%d, %.1ffps", 
                    fmt_ctx->streams[video_stream]->codecpar->width,
                    fmt_ctx->streams[video_stream]->codecpar->height,
                    fps);
            cLog(interp, log_msg);
        }
        
        // Update metadata
        char cmd[256];
        snprintf(cmd, sizeof(cmd), 
                "VideoState::updateMetadata {%s} %.2f %.2f %d",
                videoPath, fps, duration, total_frames);
        Tcl_Eval(interp, cmd);
    }
    
    # Frame extractor with persistent context
    $cc proc getVideoFrame {Tcl_Interp* interp char* videoPath int targetFrame} image_t {
        // Check cache first
        image_t cachedImage;
        int isFromCache = 0;
        
        if (getCachedFrame(videoPath, targetFrame, &cachedImage)) {
            if (!isMagenta(cachedImage)) {
                isFromCache = 1;
                
                // Report cache hit
                char cmd[256];
                snprintf(cmd, sizeof(cmd), "VideoState::recordStats 1");
                Tcl_Eval(interp, cmd);
                
                return cachedImage;
            }
        }
        
        // Report cache miss
        if (!isFromCache) {
            char cmd[256];
            snprintf(cmd, sizeof(cmd), "VideoState::recordStats 0");
            Tcl_Eval(interp, cmd);
        }
        
        // Get or create video context
        int isNew = 0;
        int contextIdx = openVideoContext(videoPath, &isNew);
        if (contextIdx < 0) {
            cLog(interp, "Failed to open video");
            return generateDebugImage();
        }
        
        // Get context data
        AVFormatContext *fmt_ctx = contexts[contextIdx].fmt_ctx;
        AVCodecContext *codec_ctx = contexts[contextIdx].codec_ctx;
        int video_stream = contexts[contextIdx].video_stream;
        int lastFrameDecoded = contexts[contextIdx].lastFrameDecoded;
        
        // Allocate frames
        AVPacket *packet = av_packet_alloc();
        AVFrame *frame = av_frame_alloc();
        AVFrame *frame_rgb = av_frame_alloc();
        
        if (!packet || !frame || !frame_rgb) {
            if (packet) av_packet_free(&packet);
            if (frame) av_frame_free(&frame);
            if (frame_rgb) av_frame_free(&frame_rgb);
            return generateDebugImage();
        }
        
        // Get video info
        double fps = av_q2d(fmt_ctx->streams[video_stream]->avg_frame_rate);
        double duration = fmt_ctx->duration / (double)AV_TIME_BASE;
        
        // Current frame tracking 
        int currentFrame = 0;
        
        // For short videos just start from beginning
        if (duration < 3.0) {
            av_seek_frame(fmt_ctx, video_stream, 0, AVSEEK_FLAG_BACKWARD);
            avcodec_flush_buffers(codec_ctx);
        }
        // For sequential access, don't seek if this is the next frame
        else if (lastFrameDecoded > 0 && targetFrame == lastFrameDecoded + 1) {
            currentFrame = lastFrameDecoded;
        }
        // Otherwise seek to appropriate position
        else {
            double seekSec = (targetFrame > 30) ? (targetFrame - 30) / fps : 0;
            int64_t seekTS = av_rescale_q(seekSec * AV_TIME_BASE, 
                                        AV_TIME_BASE_Q,
                                        fmt_ctx->streams[video_stream]->time_base);
            
            av_seek_frame(fmt_ctx, video_stream, seekTS, AVSEEK_FLAG_BACKWARD);
            avcodec_flush_buffers(codec_ctx);
        }
        
        // Process frames
        int frameFound = 0;
        int maxFramesRead = (duration < 3.0) ? 300 : 100;
        
        while (!frameFound && av_read_frame(fmt_ctx, packet) >= 0 && currentFrame < maxFramesRead) {
            if (packet->stream_index != video_stream) {
                av_packet_unref(packet);
                continue;
            }
            
            if (avcodec_send_packet(codec_ctx, packet) < 0) {
                av_packet_unref(packet);
                continue;
            }
            
            while (!frameFound && avcodec_receive_frame(codec_ctx, frame) >= 0) {
                currentFrame++;
                
                if (currentFrame == targetFrame) {
                    frameFound = 1;
                    
                    // Skip invalid frames
                    if (!frame->data[0]) {
                        frameFound = 0;
                        break;
                    }
                    
                    // Compute dimensions
                    float scale = 1.0;
                    int width = frame->width;
                    int height = frame->height;
                    
                    // Limit dimensions for memory efficiency
                    if (height > 360) {
                        scale = 360.0 / height;
                        width = (int)(width * scale);
                        height = 360;
                    }
                    
                    // Log frame processing
                    char log_msg[256];
                    snprintf(log_msg, sizeof(log_msg), 
                            "Processing frame %d: %dx%d → %dx%d", 
                            targetFrame, frame->width, frame->height, width, height);
                    cLog(interp, log_msg);
                    
                    // Set up RGB conversion
                    frame_rgb->format = AV_PIX_FMT_RGB24;
                    frame_rgb->width = width;
                    frame_rgb->height = height;
                    
                    int bufferSize = av_image_get_buffer_size(AV_PIX_FMT_RGB24, width, height, 1);
                    if (bufferSize <= 0) {
                        frameFound = 0;
                        break;
                    }
                    
                    uint8_t *buffer = (uint8_t*)av_malloc(bufferSize);
                    if (!buffer) {
                        frameFound = 0;
                        break;
                    }
                    
                    // Fill buffer
                    av_image_fill_arrays(frame_rgb->data, frame_rgb->linesize, buffer,
                                        AV_PIX_FMT_RGB24, width, height, 1);
                    
                    // Set up scaler
                    struct SwsContext *sws_ctx = sws_getContext(
                        frame->width, frame->height, codec_ctx->pix_fmt,
                        width, height, AV_PIX_FMT_RGB24,
                        SWS_BILINEAR, NULL, NULL, NULL);
                    
                    if (!sws_ctx) {
                        av_free(buffer);
                        frameFound = 0;
                        break;
                    }
                    
                    // Scale frame
                    if (sws_scale(sws_ctx, (const uint8_t* const*)frame->data, 
                                frame->linesize, 0, frame->height,
                                frame_rgb->data, frame_rgb->linesize) <= 0) {
                        sws_freeContext(sws_ctx);
                        av_free(buffer);
                        frameFound = 0;
                        break;
                    }
                    
                    // Create Folk image
                    image_t result = {0};
                    result.width = width;
                    result.height = height;
                    result.components = 4;
                    result.bytesPerRow = result.width * result.components;
                    
                    size_t imgSize = result.height * result.bytesPerRow;
                    result.data = folkHeapAlloc(imgSize);
                    
                    if (!result.data) {
                        sws_freeContext(sws_ctx);
                        av_free(buffer);
                        frameFound = 0;
                        break;
                    }
                    
                    // Copy RGB → RGBA
                    for (int y = 0; y < result.height; y++) {
                        uint8_t *dstRow = result.data + (y * result.bytesPerRow);
                        uint8_t *srcRow = frame_rgb->data[0] + (y * frame_rgb->linesize[0]);
                        
                        for (int x = 0; x < result.width; x++) {
                            uint8_t *src = srcRow + (x * 3);
                            uint8_t *dst = dstRow + (x * result.components);
                            
                            dst[0] = src[0];     // R
                            dst[1] = src[1];     // G
                            dst[2] = src[2];     // B
                            dst[3] = 255;        // A
                        }
                    }
                    
                    // Cache the frame
                    cacheFrame(videoPath, targetFrame, result);
                    
                    // Update last decoded frame
                    contexts[contextIdx].lastFrameDecoded = targetFrame;
                    
                    // Clean up scaler resources
                    sws_freeContext(sws_ctx);
                    av_free(buffer);
                    
                    // Return the image
                    av_packet_unref(packet);
                    av_frame_free(&frame_rgb);
                    av_frame_free(&frame);
                    av_packet_free(&packet);
                    
                    return result;
                }
            }
            
            av_packet_unref(packet);
        }
        
        // Clean up
        av_frame_free(&frame_rgb);
        av_frame_free(&frame);
        av_packet_free(&packet);
        
        // If frame not found, return debug image
        return generateDebugImage();
    }
    
    # Clear cache
    $cc proc freeCache {Tcl_Interp* interp} void {
        cleanupAll();
        cLog(interp, "Freed all video resources");
    }

    $cc compile
    init

    namespace export *
    namespace ensemble create
}

# Return the version for inclusion check
return 1.0