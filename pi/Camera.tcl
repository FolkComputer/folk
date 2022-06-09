# wip

package require critcl
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

critcl::argtype camera_t* {
    sscanf(Tcl_GetString(@@), "(camera_t*) 0x%p", &@A);
} camera_t*

critcl::resulttype camera_t* {
    Tcl_SetObjResult(interp, Tcl_ObjPrintf("(camera_t*) 0x%x", (size_t) rv));
    return TCL_OK;
} camera_t*

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

critcl::cproc cameraHeadImage {camera_t* camera} int {

    
}

# puts [critcl::code]

critcl::config keepsrc true

set camera [cameraOpen "/dev/video0" 1280 720]
puts "camera: $camera"
cameraInit $camera
cameraStart $camera
puts "camera!"
# skip 5 frames for booting a cam
for {set i 0} {$i < 5} {incr i} {
    cameraFrame $camera
}

while true {
    cameraFrame $camera
    set im [yuyv2gray [cameraHeadImage $camera] 1280 720]
    Display::drawImage
}
