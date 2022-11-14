package require critcl
source "pi/critclUtils.tcl"

critcl::tcl 8.6
critcl::cflags -I$::env(HOME)/apriltag -Wall -Werror
critcl::clibraries $::env(HOME)/apriltag/libapriltag.a [lindex [exec /usr/sbin/ldconfig -p | grep libjpeg] end]
critcl::debug symbols

critcl::ccode {
    #include <apriltag.h>
    #include <tagStandard52h13.h>
    #include <math.h>
}

critcl::ccode {
    #include <errno.h>
    
    #include <fcntl.h>
    #include <sys/ioctl.h>
    #include <sys/mman.h>
    #include <asm/types.h>
    #include <linux/videodev2.h>

    #include <stdint.h>
    #include <stdlib.h>

    #include <jpeglib.h>

    typedef struct {
        uint8_t* start;
        size_t length;
    } buffer_t;

    typedef struct {
        int fd;
        uint32_t width;
        uint32_t height;
        size_t buffer_count;
        buffer_t* buffers;
        buffer_t head;
    } camera_t;

    void quit(const char* msg)
    {
        fprintf(stderr, "[%s] %d: %s\n", msg, errno, strerror(errno));
        exit(1);
    }

    int xioctl(int fd, int request, void* arg)
    {
        for (int i = 0; i < 100; i++) {
            int r = ioctl(fd, request, arg);
            if (r != -1 || errno != EINTR) return r;
            printf("[%x][%d] %s\n", request, i, strerror(errno));
        }
        return -1;
    }
}
opaquePointerType camera_t*
opaquePointerType uint8_t*

critcl::cproc cameraOpen {char* device int width int height} camera_t* {
    printf("device [%s]\n", device);
    int fd = open(device, O_RDWR | O_NONBLOCK, 0);
    if (fd == -1) quit("open");
    camera_t* camera = malloc(sizeof (camera_t));
    camera->fd = fd;
    camera->width = width;
    camera->height = height;
    camera->buffer_count = 0;
    camera->buffers = NULL;
    camera->head.length = 0;
    camera->head.start = NULL;
    return camera;
}
    
critcl::cproc cameraInit {camera_t* camera} void {
    struct v4l2_capability cap;
    if (xioctl(camera->fd, VIDIOC_QUERYCAP, &cap) == -1) quit("VIDIOC_QUERYCAP");
    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) quit("no capture");
    if (!(cap.capabilities & V4L2_CAP_STREAMING)) quit("no streaming");

    struct v4l2_format format;
    memset(&format, 0, sizeof format);
    format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    format.fmt.pix.width = camera->width;
    format.fmt.pix.height = camera->height;
    format.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
    format.fmt.pix.field = V4L2_FIELD_NONE;
    if (xioctl(camera->fd, VIDIOC_S_FMT, &format) == -1) quit("VIDIOC_S_FMT");

    struct v4l2_requestbuffers req;
    memset(&req, 0, sizeof req);
    req.count = 4;
    req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    req.memory = V4L2_MEMORY_MMAP;
    if (xioctl(camera->fd, VIDIOC_REQBUFS, &req) == -1) quit("VIDIOC_REQBUFS");
    camera->buffer_count = req.count;
    camera->buffers = calloc(req.count, sizeof (buffer_t));

    size_t buf_max = 0;
    for (size_t i = 0; i < camera->buffer_count; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof buf);
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(camera->fd, VIDIOC_QUERYBUF, &buf) == -1)
            quit("VIDIOC_QUERYBUF");
        if (buf.length > buf_max) buf_max = buf.length;
        camera->buffers[i].length = buf.length;
        camera->buffers[i].start = 
            mmap(NULL, buf.length, PROT_READ | PROT_WRITE, MAP_SHARED, 
                 camera->fd, buf.m.offset);
        if (camera->buffers[i].start == MAP_FAILED) quit("mmap");
    }
    camera->head.start = malloc(buf_max);

    printf("camera %d; bufcount %zu\n", camera->fd, camera->buffer_count);
}

critcl::cproc cameraStart {camera_t* camera} void {
    for (size_t i = 0; i < camera->buffer_count; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof buf);
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(camera->fd, VIDIOC_QBUF, &buf) == -1) quit("VIDIOC_QBUF");
        printf("camera_start(%zu): %s\n", i, strerror(errno));
    }

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(camera->fd, VIDIOC_STREAMON, &type) == -1) 
        quit("VIDIOC_STREAMON");
}

critcl::ccode {
int camera_capture(camera_t* camera) {
  struct v4l2_buffer buf;
  memset(&buf, 0, sizeof buf);
  buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  buf.memory = V4L2_MEMORY_MMAP;
  if (xioctl(camera->fd, VIDIOC_DQBUF, &buf) == -1) return 0;
  memcpy(camera->head.start, camera->buffers[buf.index].start, buf.bytesused);
  camera->head.length = buf.bytesused;
  if (xioctl(camera->fd, VIDIOC_QBUF, &buf) == -1) return 0;
  return 1;
}
}

critcl::cproc cameraFrame {camera_t* camera} int {
    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;

    fd_set fds;
    FD_ZERO(&fds);
    FD_SET(camera->fd, &fds);
    int r = select(camera->fd + 1, &fds, 0, 0, &timeout);
    // printf("r: %d\n", r);
    if (r == -1) quit("select");
    if (r == 0) {
        printf("selection failed of fd %d\n", camera->fd);
        return 0;
    }
    return camera_capture(camera);
}

critcl::cproc cameraDecompressRgb {camera_t* camera} uint8_t* {
      struct jpeg_decompress_struct cinfo;
      struct jpeg_error_mgr jerr;
      cinfo.err = jpeg_std_error(&jerr);
      jpeg_create_decompress(&cinfo);
      jpeg_mem_src(&cinfo, camera->head.start, camera->head.length);
      if (jpeg_read_header(&cinfo, TRUE) != 1) {
          printf("Fail\n");
          exit(1);
      }
      jpeg_start_decompress(&cinfo);

      uint8_t* rgb = 
          malloc(camera->width * camera->height * cinfo.output_components);

      while (cinfo.output_scanline < cinfo.output_height) {
          unsigned char *buffer_array[1];
          buffer_array[0] = rgb + (cinfo.output_scanline) * camera->width * cinfo.output_components;
          jpeg_read_scanlines(&cinfo, buffer_array, 1);
      }
      jpeg_finish_decompress(&cinfo);
      jpeg_destroy_decompress(&cinfo);

    return rgb;
}
critcl::cproc rgbToGray {uint8_t* rgb int width int height} uint8_t* {
    uint8_t* gray = calloc(width * height, sizeof (uint8_t));
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            int i = (y * width + x) * 3;
            uint8_t r = rgb[i];
            uint8_t g = rgb[i + 1];
            uint8_t b = rgb[i + 2];
            gray[y * width + x] = 0.299*r + 0.587*g + 0.114*b;
        }
    }
    return gray;
}
critcl::cproc freeImage {uint8_t* image} void {
  free(image);
}

namespace eval Camera {
    variable camera

    variable WIDTH
    variable HEIGHT

    proc init {width height} {
        set Camera::WIDTH $width
        set Camera::HEIGHT $height
        
        set camera [cameraOpen "/dev/video0" $Camera::WIDTH $Camera::HEIGHT]
        cameraInit $camera
        cameraStart $camera
        
        # skip 5 frames for booting a cam
        for {set i 0} {$i < 5} {incr i} {
            cameraFrame $camera
        }
        set Camera::camera $camera
    }

    proc frame {} {
        if {![cameraFrame $Camera::camera]} {
            error "Failed to capture from camera"
        }
        return [cameraDecompressRgb $Camera::camera]
    }
}

if {([info exists ::argv0] && $::argv0 eq [info script]) || \
        ([info exists ::entry] && $::entry == "pi/Camera.tcl")} {
    source pi/Display.tcl
    Display::init

    # Camera::init 3840 2160
    Camera::init 1280 720
    # Camera::init 1920 1080
    puts "camera: $Camera::camera"

    while true {
        set rgb [Camera::frame]
        set gray [rgbToGray $rgb $Camera::WIDTH $Camera::HEIGHT]
        freeImage $rgb
        Display::grayImage $Display::fb $Display::WIDTH $Display::HEIGHT $gray $Camera::WIDTH $Camera::HEIGHT
        freeImage $gray
    }
}


namespace eval AprilTags {
    critcl::ccode {
        apriltag_detector_t *td;
        apriltag_family_t *tf;
    }

    critcl::cproc detectInit {} void {
        td = apriltag_detector_create();
        tf = tagStandard52h13_create();
        apriltag_detector_add_family_bits(td, tf, 1);
        td->nthreads = 2;
    }

    critcl::cproc detectImpl {uint8_t* gray int width int height} Tcl_Obj*0 {
        image_u8_t im = (image_u8_t) { .width = width, .height = height, .stride = width, .buf = gray };
    
        zarray_t *detections = apriltag_detector_detect(td, &im);
        int detectionCount = zarray_size(detections);

        Tcl_Obj* detectionObjs[detectionCount];
        for (int i = 0; i < detectionCount; i++) {
            apriltag_detection_t *det;
            zarray_get(detections, i, &det);

            int size = sqrt((det->p[0][0] - det->p[1][0])*(det->p[0][0] - det->p[1][0]) + (det->p[0][1] - det->p[1][1])*(det->p[0][1] - det->p[1][1]));
            detectionObjs[i] = Tcl_ObjPrintf("id %d center {%f %f} corners {{%f %f} {%f %f} {%f %f} {%f %f}} size %d",
                                             det->id,
                                             det->c[0], det->c[1],
                                             det->p[0][0], det->p[0][1],
                                             det->p[1][0], det->p[1][1],
                                             det->p[2][0], det->p[2][1],
                                             det->p[3][0], det->p[3][1],
                                             size);
        }
        

        zarray_destroy(detections);
        Tcl_Obj* result = Tcl_NewListObj(detectionCount, detectionObjs);
        return result;
    }

    critcl::cproc detectCleanup {} void {
        tagStandard52h13_destroy(tf);
        apriltag_detector_destroy(td);
    }
    
    proc init {} {
        detectInit
    }

    proc detect {gray} {
        return [detectImpl $gray $Camera::WIDTH $Camera::HEIGHT]
    }
}
