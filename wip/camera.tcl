# wip

Claim "/dev/video0" is a camera

When /camera/ is a camera {
    # camera_init(camera)
    C {
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

    # camera_start(camera)
    C {
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
    
}

