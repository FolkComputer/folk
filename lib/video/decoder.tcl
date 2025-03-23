# video/decoder.tcl
# Video decoding implementation for Folk

namespace eval video {
    # Create C compiler instance
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
    $cc include <time.h>
    $cc include <libavutil/imgutils.h>
    $cc include <libavcodec/avcodec.h>
    $cc include <libavformat/avformat.h>
    $cc include <libswscale/swscale.h>

    $cc import ::Heap::cc folkHeapAlloc as folkHeapAlloc
    $cc import ::Heap::cc folkHeapFree as folkHeapFree

    $cc proc init {} void {}
    
    # Simple logging function with improved escape handling
    $cc code {
        static void cLog(Tcl_Interp* interp, char* msg) {
            if (!interp) {
                // Safeguard against NULL interpreter
                fprintf(stderr, "[VIDEO:C] %s\n", msg);
                return;
            }
            
            // Use a larger buffer to avoid truncation
            char cmd[1024];
            
            // Make a copy of the message for escaping
            char escMsg[768];
            strncpy(escMsg, msg, sizeof(escMsg)-1);
            escMsg[sizeof(escMsg)-1] = '\0';
            
            // Escape braces and backslashes - fixed escaping
            for (char* p = escMsg; *p; p++) {
                if (*p == '{' || *p == '}' || *p == '\\' || *p == '[' || *p == ']') {
                    *p = ' '; // Replace with space for safety
                }
            }
            
            // Determine log level based on message content
            int logLevel = 0; // Default to highest priority
            
            // Check for common messages that should be level 1 (less critical)
            if (strstr(escMsg, "Requesting frame") || 
                strstr(escMsg, "Cache hit for frame")) {
                logLevel = 1; // These are frequent and verbose, so log at level 1
            }
            
            // Use the appropriate log level
            snprintf(cmd, sizeof(cmd), "VideoState::log %d {%s}", logLevel, escMsg);
            Tcl_Eval(interp, cmd);
        }
    }
    
    # Debug image generator - made larger and more visible with pattern
    $cc proc generateDebugImage {Tcl_Interp* interp} image_t {
        image_t ret;
        ret.width = 256;  // Larger to be more noticeable
        ret.height = 144; // 16:9 aspect ratio
        ret.components = 4;
        ret.bytesPerRow = ret.width * ret.components;
        ret.data = folkHeapAlloc(ret.bytesPerRow * ret.height);
        
        if (ret.data) {
            // Fill with a checkered debug pattern (magenta and black)
            for (int y = 0; y < ret.height; y++) {
                for (int x = 0; x < ret.width; x++) {
                    int offset = y * ret.bytesPerRow + x * ret.components;
                    int cellSize = 16; // Size of each checker square
                    int isEvenCell = ((x / cellSize) + (y / cellSize)) % 2;
                    
                    if (isEvenCell) {
                        // Magenta for even cells
                        ret.data[offset] = 255;     // R
                        ret.data[offset + 1] = 0;   // G
                        ret.data[offset + 2] = 255; // B
                    } else {
                        // Black for odd cells
                        ret.data[offset] = 30;      // R
                        ret.data[offset + 1] = 30;  // G
                        ret.data[offset + 2] = 30;  // B
                    }
                    
                    // Draw "DEBUG" text in center by checking coordinates
                    int centerY = ret.height / 2;
                    int centerX = ret.width / 2;
                    if (abs(y - centerY) < 20 && abs(x - centerX) < 50) {
                        // Simple text effect - brighten a pattern to make text
                        if ((y % 4) < 2 && (x % 4) < 2) {
                            ret.data[offset] = 255;     // R
                            ret.data[offset + 1] = 255; // G
                            ret.data[offset + 2] = 255; // B
                        }
                    }
                    
                    ret.data[offset + 3] = 255; // A - always fully opaque
                }
            }
        }
        
        // Log when a debug image is generated - important to diagnose issues
        if (interp) {
            cLog(interp, "WARNING: Generated debug image due to missing frame data");
        }
        return ret;
    }
    
    # Cache and video context implementation
    $cc code {
        // --- Cache structures with improved tracking ---
        typedef struct {
            image_t frame;
            int frameNumber;
            char path[256];
            int valid;
            int64_t lastAccessed;  // Timestamp for LRU replacement
            int accessCount;       // How many times this frame was accessed
        } CacheEntry;
        
        // --- Video context for keeping files open ---
        typedef struct {
            AVFormatContext *fmt_ctx;
            AVCodecContext *codec_ctx;
            int video_stream;
            int lastFrameDecoded;
            int isActive;
            char path[256];
            int64_t lastAccessed;  // Last time this context was used
            int decodeErrors;      // Track decode errors to detect problematic files
        } VideoContext;
        
        #define CACHE_SIZE 40   // Increased cache size for smoother playback
        #define MAX_CONTEXTS 3  // Allow more open video contexts
        
        CacheEntry frameCache[CACHE_SIZE];
        VideoContext contexts[MAX_CONTEXTS];
        int nextCacheSlot = 0;
        int initialized = 0;
        
        // Initialize cache and contexts
        void initializeCache() {
            if (initialized) return;
            
            // Current time for initialization
            int64_t currentTime = (int64_t)time(NULL);
            
            // Init cache
            for (int i = 0; i < CACHE_SIZE; i++) {
                frameCache[i].frame.data = NULL;
                frameCache[i].valid = 0;
                frameCache[i].path[0] = '\0';
                frameCache[i].frameNumber = -1;
                frameCache[i].lastAccessed = currentTime;
                frameCache[i].accessCount = 0;
            }
            
            // Init contexts
            for (int i = 0; i < MAX_CONTEXTS; i++) {
                contexts[i].fmt_ctx = NULL;
                contexts[i].codec_ctx = NULL;
                contexts[i].video_stream = -1;
                contexts[i].lastFrameDecoded = -1;
                contexts[i].isActive = 0;
                contexts[i].path[0] = '\0';
                contexts[i].lastAccessed = currentTime;
                contexts[i].decodeErrors = 0;
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
            
            initialized = 0;
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
        
        // Get a cached frame with improved LRU tracking
        int getCachedFrame(const char* path, int frameNum, image_t* outImage) {
            initializeCache();
            
            // Current time for LRU tracking
            int64_t currentTime = (int64_t)time(NULL);
            
            // Find in cache
            for (int i = 0; i < CACHE_SIZE; i++) {
                if (frameCache[i].valid && 
                    frameCache[i].frameNumber == frameNum &&
                    strcmp(frameCache[i].path, path) == 0) {
                    
                    // Update access statistics
                    frameCache[i].lastAccessed = currentTime;
                    frameCache[i].accessCount++;
                    
                    // Return the frame
                    *outImage = frameCache[i].frame;
                    return 1;
                }
            }
            
            // Also look for nearby frames - this helps with smooth playback
            // when frames are missing but adjacent ones are available
            for (int i = 0; i < CACHE_SIZE; i++) {
                if (frameCache[i].valid && 
                    abs(frameCache[i].frameNumber - frameNum) <= 2 &&
                    strcmp(frameCache[i].path, path) == 0) {
                    
                    // Update access statistics
                    frameCache[i].lastAccessed = currentTime;
                    frameCache[i].accessCount++;
                    
                    // Return the close frame as a temporary substitute
                    *outImage = frameCache[i].frame;
                    return 1;
                }
            }
            
            return 0;
        }
        
        // Enhanced frame caching with improved LRU replacement policy
        void cacheFrame(const char* path, int frameNum, image_t image) {
            initializeCache();
            
            // Current time for LRU tracking
            int64_t currentTime = (int64_t)time(NULL);
            
            // Don't cache debug frames
            if (isMagenta(image)) return;
            
            // Check if already cached
            for (int i = 0; i < CACHE_SIZE; i++) {
                if (frameCache[i].valid && 
                    frameCache[i].frameNumber == frameNum &&
                    strcmp(frameCache[i].path, path) == 0) {
                    // Just update access time and count
                    frameCache[i].lastAccessed = currentTime;
                    frameCache[i].accessCount++;
                    return;
                }
            }
            
            // Advanced caching strategy:
            // 1. Try to find an empty slot first
            // 2. If no empty slots, use LRU replacement for frames from different paths
            // 3. If all slots are from current path, replace frames that are far from current
            // 4. If no good candidates, replace least recently accessed frame
            
            int slotToUse = -1;
            int maxDistance = 0;
            int64_t oldestAccess = currentTime + 1; // Initialize to newer than current time
            int leastAccessedSlot = -1;
            
            // First look for an empty slot
            for (int i = 0; i < CACHE_SIZE; i++) {
                if (!frameCache[i].valid || frameCache[i].frame.data == NULL) {
                    slotToUse = i;
                    break;
                }
                
                // Track least recently accessed frame as fallback
                if (frameCache[i].lastAccessed < oldestAccess) {
                    oldestAccess = frameCache[i].lastAccessed;
                    leastAccessedSlot = i;
                }
                
                // Calculate frame distance for frames from same path
                if (strcmp(frameCache[i].path, path) == 0) {
                    int distance = abs(frameCache[i].frameNumber - frameNum);
                    // Prioritize replacing frames that are far from current frame
                    if (distance > maxDistance) {
                        maxDistance = distance;
                        // More aggressive replacement - use smaller threshold for replacing frames
                        if (distance > 30) {
                            slotToUse = i;
                        }
                    }
                }
            }
            
            // If no good slot found based on distance, use LRU replacement
            if (slotToUse < 0) {
                if (leastAccessedSlot >= 0) {
                    slotToUse = leastAccessedSlot;
                } else {
                    // Fallback to round-robin if LRU fails somehow
                    slotToUse = nextCacheSlot;
                    nextCacheSlot = (nextCacheSlot + 1) % CACHE_SIZE;
                }
            }
            
            // Free old frame if present
            if (frameCache[slotToUse].frame.data) {
                folkHeapFree(frameCache[slotToUse].frame.data);
            }
            
            // Store new frame with tracking info
            strncpy(frameCache[slotToUse].path, path, 255);
            frameCache[slotToUse].frameNumber = frameNum;
            frameCache[slotToUse].frame = image;
            frameCache[slotToUse].valid = 1;
            frameCache[slotToUse].lastAccessed = (int64_t)time(NULL);
            frameCache[slotToUse].accessCount = 1; // Initial access count
        }
        
        // Open or get existing video context with improved error handling
        int openVideoContext(Tcl_Interp* interp, char* path, int* isNew) {
            if (!path || path[0] == '\0') {
                if (interp) {
                    cLog(interp, "ERROR: Invalid video path (null or empty)");
                }
                *isNew = 0;
                return -1;
            }
            
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
            if (interp) {
                char opening_msg[512];
                snprintf(opening_msg, sizeof(opening_msg), "Opening video context for: %s", path);
                cLog(interp, opening_msg);
            }
            
            // Check if file exists and is readable first
            FILE* testFile = fopen(path, "rb");
            if (!testFile) {
                char error_msg[512];
                snprintf(error_msg, sizeof(error_msg), 
                        "ERROR: Cannot open video file: %s (file does not exist or is not readable)", path);
                if (interp) {
                    cLog(interp, error_msg);
                }
                return -1;
            }
            fclose(testFile);
            
            // Now try to open with libav
            int open_result = avformat_open_input(&fmt_ctx, path, NULL, NULL);
            if (open_result != 0) {
                char error_msg[512];
                char av_error[256];
                av_strerror(open_result, av_error, sizeof(av_error));
                snprintf(error_msg, sizeof(error_msg), 
                        "ERROR: Cannot open video file with libav: %s (error: %s)", path, av_error);
                cLog(interp, error_msg);
                return -1;
            }
            
            int find_result = avformat_find_stream_info(fmt_ctx, NULL);
            if (find_result < 0) {
                char error_msg[512];
                char av_error[256];
                av_strerror(find_result, av_error, sizeof(av_error));
                snprintf(error_msg, sizeof(error_msg), 
                        "ERROR: Cannot find stream info: %s (error: %s)", path, av_error);
                cLog(interp, error_msg);
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
            
            // Store context with access timestamp
            contexts[idx].fmt_ctx = fmt_ctx;
            contexts[idx].codec_ctx = codec_ctx;
            contexts[idx].video_stream = video_stream;
            contexts[idx].lastFrameDecoded = -1;
            contexts[idx].isActive = 1;
            contexts[idx].lastAccessed = (int64_t)time(NULL);
            contexts[idx].decodeErrors = 0; // Reset error count
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
        int contextIdx = openVideoContext(interp, videoPath, &isNew);
        
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
    
    # Frame extractor with improved error handling and diagnostics
    $cc proc getVideoFrame {Tcl_Interp* interp char* videoPath int targetFrame} image_t {
        // Validate input parameters
        if (!videoPath || videoPath[0] == '\0') {
            if (interp) {
                cLog(interp, "CRITICAL ERROR: Empty video path provided to getVideoFrame");
            }
            return generateDebugImage(interp);
        }
        
        if (targetFrame <= 0) {
            char err_msg[128];
            snprintf(err_msg, sizeof(err_msg), "CRITICAL ERROR: Invalid frame number (%d)", targetFrame);
            if (interp) {
                cLog(interp, err_msg);
            }
            targetFrame = 1; // Force to frame 1 as fallback
        }
        
        // Log frame request
        if (interp) {
            char request_msg[256];
            snprintf(request_msg, sizeof(request_msg), 
                    "Requesting frame %d from %s", targetFrame, videoPath);
            cLog(interp, request_msg);
        }
        
        // Check cache first
        image_t cachedImage;
        int isFromCache = 0;
        
        if (getCachedFrame(videoPath, targetFrame, &cachedImage)) {
            if (!isMagenta(cachedImage)) {
                isFromCache = 1;
                
                // Report cache hit
                if (interp) {
                    char cmd[256];
                    snprintf(cmd, sizeof(cmd), "VideoState::recordStats 1");
                    Tcl_Eval(interp, cmd);
                    
                    // Log cache hit at debug level
                    cLog(interp, "Cache hit for frame");
                }
                
                return cachedImage;
            } else {
                // If we got a magenta frame from cache, log this
                if (interp) {
                    cLog(interp, "Found debug frame in cache, will try to regenerate");
                }
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
        int contextIdx = openVideoContext(interp, videoPath, &isNew);
        if (contextIdx < 0) {
            cLog(interp, "Failed to open video");
            return generateDebugImage(interp);
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
            return generateDebugImage(interp);
        }
        
        // Get video info
        double fps = av_q2d(fmt_ctx->streams[video_stream]->avg_frame_rate);
        double duration = fmt_ctx->duration / (double)AV_TIME_BASE;
        
        // Current frame tracking 
        int currentFrame = 0;
        
        // Improved seeking strategy based on video duration and target frame
        char log_msg[256];
        
        // Smart seeking based on several conditions
        if (duration < 3.0) {
            // Short videos: Optimize for loop transitions by seeking to beginning for most frames
            // For very short videos this reduces stuttering during loop transitions
            if (targetFrame < 5) {
                // For first few frames, always seek to the start
                snprintf(log_msg, sizeof(log_msg), "Short video, seeking to start (frame %d)", targetFrame);
                cLog(interp, log_msg);
                av_seek_frame(fmt_ctx, video_stream, 0, AVSEEK_FLAG_BACKWARD);
                avcodec_flush_buffers(codec_ctx);
            } 
            else if (lastFrameDecoded > 0 && abs(targetFrame - lastFrameDecoded) <= 5) {
                // For nearby frames, use sequential access
                snprintf(log_msg, sizeof(log_msg), "Short video, sequential access from frame %d to %d", 
                         lastFrameDecoded, targetFrame);
                cLog(interp, log_msg);
                currentFrame = lastFrameDecoded;
            }
            else {
                // For other frames, seek to a point slightly before the target
                // This helps with keyframe decoding dependencies
                double seekSec = (targetFrame > 10) ? (targetFrame - 10) / fps : 0;
                int64_t seekTS = av_rescale_q(seekSec * AV_TIME_BASE, 
                                           AV_TIME_BASE_Q,
                                           fmt_ctx->streams[video_stream]->time_base);
                
                snprintf(log_msg, sizeof(log_msg), "Short video, targeted seek to %.2fs for frame %d", 
                         seekSec, targetFrame);
                cLog(interp, log_msg);
                av_seek_frame(fmt_ctx, video_stream, seekTS, AVSEEK_FLAG_BACKWARD);
                avcodec_flush_buffers(codec_ctx);
            }
        }
        // For sequential access, don't seek if this is the next frame or very close
        else if (lastFrameDecoded > 0 && abs(targetFrame - lastFrameDecoded) <= 3) {
            snprintf(log_msg, sizeof(log_msg), "Sequential access from frame %d to %d", 
                     lastFrameDecoded, targetFrame);
            cLog(interp, log_msg);
            currentFrame = lastFrameDecoded;
        }
        // For random access or big jumps, seek smarter
        else {
            // Calculate optimal seek position:
            // - For small target frames, seek to beginning
            // - For higher target frames, seek to adaptive distance before the target
            // - The distance scales with the frame number to handle keyframe dependencies
            int offset = targetFrame < 30 ? targetFrame : (20 + targetFrame / 10);
            double seekSec = (targetFrame > offset) ? (targetFrame - offset) / fps : 0;
            int64_t seekTS = av_rescale_q(seekSec * AV_TIME_BASE, 
                                       AV_TIME_BASE_Q,
                                       fmt_ctx->streams[video_stream]->time_base);
            
            snprintf(log_msg, sizeof(log_msg), "Smart seek to %.2fs for frame %d (offset %d)", 
                     seekSec, targetFrame, offset);
            cLog(interp, log_msg);
            av_seek_frame(fmt_ctx, video_stream, seekTS, AVSEEK_FLAG_BACKWARD);
            avcodec_flush_buffers(codec_ctx);
        }
        
        // Process frames with adaptive frame limit
        int frameFound = 0;
        // Adjust max frames to read based on video properties:
        // - Short videos: higher limit to ensure we find the frame
        // - Long videos with far target: much higher limit as we might need to decode more frames
        // - Standard case: moderate limit to avoid excessive decoding
        int maxDistance = lastFrameDecoded > 0 ? abs(targetFrame - lastFrameDecoded) : targetFrame;
        int maxFramesRead = 300;  // Default higher value
        
        // Increase limit for higher frame distances
        if (maxDistance > 50) {
            maxFramesRead = 500;
        }
        
        snprintf(log_msg, sizeof(log_msg), "Frame search limit: %d frames", maxFramesRead);
        cLog(interp, log_msg);
        
        while (!frameFound && av_read_frame(fmt_ctx, packet) >= 0 && currentFrame < maxFramesRead) {
            // Log diagnostic info every ~100 frames during seeking
            if (currentFrame % 100 == 0) {
                char progress_msg[256];
                snprintf(progress_msg, sizeof(progress_msg), 
                        "Seeking progress: processed %d frames, looking for target frame %d",
                        currentFrame, targetFrame);
                cLog(interp, progress_msg);
            }
            
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
                    
                    // Ensure dimensions are even (required by some codecs/GPU textures)
                    width = width & ~1;   // Clear last bit to ensure even
                    height = height & ~1; // Clear last bit to ensure even
                    
                    // Minimum size check
                    if (width < 16) width = 16;
                    if (height < 16) height = 16;
                    
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
        
        // If frame not found, log useful info and return debug image
        char debug_msg[512];
        snprintf(debug_msg, sizeof(debug_msg), 
                "Failed to find frame %d after reading %d frames (limit: %d). Video: %s",
                targetFrame, currentFrame, maxFramesRead, videoPath);
        cLog(interp, debug_msg);
        
        // Try to provide additional diagnostic information
        if (fmt_ctx && fmt_ctx->streams && video_stream >= 0) {
            AVStream* stream = fmt_ctx->streams[video_stream];
            if (stream && stream->codecpar) {
                snprintf(debug_msg, sizeof(debug_msg), 
                        "Video info: %dx%d, codec %d, time_base %d/%d, max frames ~%d",
                        stream->codecpar->width, 
                        stream->codecpar->height,
                        stream->codecpar->codec_id,
                        stream->time_base.num,
                        stream->time_base.den,
                        (int)(duration * fps));
                cLog(interp, debug_msg);
            }
        }
        
        return generateDebugImage(interp);
    }
    
    # Clear cache
    $cc proc freeCache {Tcl_Interp* interp} void {
        cleanupAll();
        cLog(interp, "Freed all video resources");
    }

    $cc compile
    init

    namespace export getVideoFrame analyzeVideo freeCache
    namespace ensemble create
}

# Return success
return 1