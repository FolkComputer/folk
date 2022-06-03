/*
 * capturing from UVC cam
 * build: gcc detect.c -ljpeg -o detect
 */

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <asm/types.h>
#include <linux/videodev2.h>

#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#include <apriltag.h>
#include <tagStandard52h13.h>

void quit(const char * msg)
{
  fprintf(stderr, "[%s] %d: %s\n", msg, errno, strerror(errno));
  exit(EXIT_FAILURE);
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


camera_t* camera_open(const char * device, uint32_t width, uint32_t height)
{
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


void camera_init(camera_t* camera) {
  struct v4l2_capability cap;
  if (xioctl(camera->fd, VIDIOC_QUERYCAP, &cap) == -1) quit("VIDIOC_QUERYCAP");
  if (!(cap.capabilities & V4L2_CAP_VIDEO_CAPTURE)) quit("no capture");
  if (!(cap.capabilities & V4L2_CAP_STREAMING)) quit("no streaming");

  /* struct v4l2_cropcap cropcap; */
  /* memset(&cropcap, 0, sizeof cropcap); */
  /* cropcap.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; */
  /* if (xioctl(camera->fd, VIDIOC_CROPCAP, &cropcap) == 0) { */
  /*   struct v4l2_crop crop; */
  /*   crop.type = V4L2_BUF_TYPE_VIDEO_CAPTURE; */
  /*   crop.c = cropcap.defrect; */
  /*   if (xioctl(camera->fd, VIDIOC_S_CROP, &crop) == -1) { */
  /*     // cropping not supported */
  /*   } */
  /* } */
  
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


void camera_start(camera_t* camera)
{
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

void camera_stop(camera_t* camera)
{
  enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  if (xioctl(camera->fd, VIDIOC_STREAMOFF, &type) == -1) 
    quit("VIDIOC_STREAMOFF");
}

void camera_finish(camera_t* camera)
{
  for (size_t i = 0; i < camera->buffer_count; i++) {
    munmap(camera->buffers[i].start, camera->buffers[i].length);
  }
  free(camera->buffers);
  camera->buffer_count = 0;
  camera->buffers = NULL;
  free(camera->head.start);
  camera->head.length = 0;
  camera->head.start = NULL;
}

void camera_close(camera_t* camera)
{
  if (close(camera->fd) == -1) quit("close");
  free(camera);
}


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

int camera_frame(camera_t* camera, struct timeval timeout) {
  fd_set fds;
  FD_ZERO(&fds);
  FD_SET(camera->fd, &fds);
  int r = select(camera->fd + 1, &fds, 0, 0, &timeout);
  printf("r: %d\n", r);
  if (r == -1) quit("select");
  if (r == 0) return 0;
  return camera_capture(camera);
}


int minmax(int min, int v, int max)
{
  return (v < min) ? min : (max < v) ? max : v;
}

uint8_t* yuyv2gray(uint8_t* yuyv, uint32_t width, uint32_t height)
{
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


unsigned short* fbmem;
const int FB_WIDTH = 3840;
const int FB_HEIGHT = 2160;
void fb_draw_rectangle(int x0, int x1, int y0, int y1, short color) {
    for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
            fbmem[(y * FB_WIDTH) + x] = color;
        }
    }
}


apriltag_detector_t *td;
apriltag_family_t *tf;
void detect_init() {
    td = apriltag_detector_create();
    tf = tagStandard52h13_create();
    apriltag_detector_add_family_bits(td, tf, 1);
}
void detect(uint8_t* gray, int width, int height) {
    image_u8_t im = (image_u8_t) { .width = width, .height = height, .stride = width, .buf = gray };
    
    zarray_t *detections = apriltag_detector_detect(td, &im);

    printf("DETECTION COUNT: %d\n", zarray_size(detections));
    for (int i = 0; i < zarray_size(detections); i++) {
        apriltag_detection_t *det;
        zarray_get(detections, i, &det);

        // Do stuff with detections here.
        printf("DETECTION #%d (%f, %f): ID %d\n", i, det->c[0], det->c[1], det->id);
        int size = sqrt((det->p[0][0] - det->p[1][0])*(det->p[0][0] - det->p[1][0]) + (det->p[0][1] - det->p[1][1])*(det->p[0][1] - det->p[1][1]));
        fb_draw_rectangle(det->c[0], det->c[0] + size, det->c[1], det->c[1] + size, 0xF000);
    }
}
void detect_cleanup() {
    tagStandard52h13_destroy(tf);
    apriltag_detector_destroy(td);
}

int main()
{
  camera_t* camera = camera_open("/dev/video0", 1280, 720);
  camera_init(camera);
  camera_start(camera);
  
  struct timeval timeout;
  timeout.tv_sec = 1;
  timeout.tv_usec = 0;
  /* skip 5 frames for booting a cam */
  for (int i = 0; i < 5; i++) {
    camera_frame(camera, timeout);
  }
  
  int fb = open("/dev/fb0", O_RDWR);
  fbmem = mmap(NULL, FB_WIDTH * FB_HEIGHT * 2, PROT_WRITE, MAP_SHARED, fb, 0);
  fb_draw_rectangle(0, FB_WIDTH, 0, FB_HEIGHT, 0x000F);
  
  detect_init();

  while (1) {
        // clear screen
      /* fb_draw_rectangle(0, FB_WIDTH, 0, FB_HEIGHT, 0x000F); */

      camera_frame(camera, timeout);

      uint8_t* im = 
          yuyv2gray(camera->head.start, camera->width, camera->height);
      
      /*     FILE* out = fopen("result.jpg", "w"); */
      /* jpeg(out, rgb, camera->width, camera->height, 100); */
      /* fclose(out); */

      /* for (int y = 0; y < camera->height; y++) { */
      /*     for (int x = 0; x < camera->width; x++) { */
      /*         int i = (y * camera->width + x); */
      /*         uint8_t r = im[i]; */
      /*         uint8_t g = im[i]; */
      /*         uint8_t b = im[i]; */
      /*         fbmem[((y + 300) * FB_WIDTH) + (x + 300)] = */
      /*             (((r >> 3) & 0x1F) << 11) | */
      /*             (((g >> 2) & 0x3F) << 5) | */
      /*             ((b >> 3) & 0x1F); */
      /*     } */
      /* } */

      detect(im, camera->width, camera->height);

      free(im);
  }

  detect_cleanup();
  
  camera_stop(camera);
  camera_finish(camera);
  camera_close(camera);
  return 0;
}
