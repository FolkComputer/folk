# wip

package require critcl
source pi/critclUtils.tcl

critcl::ccode {
    #include <errno.h>
    
    #include <fcntl.h>
    #include <sys/ioctl.h>
    #include <sys/mman.h>
    #include <asm/types.h>
    #include <linux/videodev2.h>

    #include <stdint.h>
    #include <stdlib.h>

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
            printf("[%x][%d] %s\n", request, i, strerror(errno));
            if (r != -1 || errno != EINTR) return r;
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
    printf("camera %d %d\n", camera->fd, camera->width);
    return camera;
}
    
critcl::cproc cameraInit {camera_t* camera} void {
    printf("camera %d %d\n", camera->fd, camera->width);

    struct v4l2_capability cap;
    if (xioctl(camera->fd, VIDIOC_QUERYCAP, &cap) == -1) quit("VIDIOC_QUERYCAP");
    if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) quit("no capture");
    if (!(cap.capabilities & V4L2_CAP_STREAMING)) quit("no streaming");

    struct v4l2_format format;
    memset(&format, 0, sizeof format);
    format.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    format.fmt.pix.width = camera->width;
    format.fmt.pix.height = camera->height;
    format.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
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
}

critcl::cproc cameraStart {camera_t* camera} void {
    for (size_t i = 0; i < camera->buffer_count; i++) {
        struct v4l2_buffer buf;
        memset(&buf, 0, sizeof buf);
        buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i;
        if (xioctl(camera->fd, VIDIOC_QBUF, &buf) == -1) quit("VIDIOC_QBUF");
        printf("camera_start(%d): %s\n", i, strerror(errno));
    }

    enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
    if (xioctl(camera->fd, VIDIOC_STREAMON, &type) == -1) 
        quit("VIDIOC_STREAMON");
}

critcl::ccode {
int camera_capture(camera_t* camera)
{
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
    printf("r: %d\n", r);
    if (r == -1) quit("select");
    if (r == 0) return 0;
    return camera_capture(camera);
}

critcl::cproc cameraHeadImage {camera_t* camera} uint8_t* {
    return camera->head.start;
}
critcl::cproc yuyv2gray {uint8_t* yuyv int width int height} uint8_t* {
  uint8_t* gray = calloc(width * height, sizeof (uint8_t));
  for (size_t i = 0; i < height; i++) {
    for (size_t j = 0; j < width; j += 2) {
      size_t index = i * width + j;
      int y0 = yuyv[index * 2 + 0];
      int y1 = yuyv[index * 2 + 2];
      gray[index] = y0; 
      gray[index + 1] = y1;
    }
  }
  return gray;
}

opaquePointerType uint16_t*
critcl::cproc drawGrayImage {uint16_t* fbmem int fbwidth uint8_t* im int width int height} void {
 for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
              int i = (y * width + x);
              uint8_t r = im[i];
              uint8_t g = im[i];
              uint8_t b = im[i];
              fbmem[((y + 300) * fbwidth) + (x + 300)] =
                  (((r >> 3) & 0x1F) << 11) |
                  (((g >> 2) & 0x3F) << 5) |
                  ((b >> 3) & 0x1F);
          }
      }
}

critcl::config keepsrc true

namespace eval Camera {
    variable camera

    proc init {} {
        set camera [cameraOpen "/dev/video0" 1280 720]
        cameraInit $camera
        cameraStart $camera
        
        # skip 5 frames for booting a cam
        for {set i 0} {$i < 5} {incr i} {
            cameraFrame $camera
        }
        set Camera::camera $camera
    }

    proc frame {} {
        cameraFrame $Camera::camera
        return [cameraHeadImage $Camera::camera]
    }
}

if {$::argv0 eq [info script]} {
    source pi/Display.tcl
    Display::init

    Camera::init
    puts "camera: $Camera::camera"

    while true {
        set im [yuyv2gray [Camera::frame] 1280 720]
        puts $im
        drawGrayImage $Display::fb $Display::WIDTH $im 1280 720
    }
}
