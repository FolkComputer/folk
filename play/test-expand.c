//usr/bin/cc -o test-expand "$0" && exec ./test-expand "$@"
#include <linux/videodev2.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>

int main() {
    printf("VIDIOC_QUERYCAP = 0x%x\n", VIDIOC_QUERYCAP);
    printf("VIDIOC_CROPCAP = 0x%x\n", VIDIOC_CROPCAP);
    printf("V4L2_PIX_FMT_YUYV = 0x%x\n", V4L2_PIX_FMT_YUYV);
    printf("VIDIOC_S_FMT = 0x%x\n", VIDIOC_S_FMT);
    printf("VIDIOC_REQBUFS = 0x%x\n", VIDIOC_REQBUFS);
    printf("VIDIOC_QBUF = 0x%x\n", VIDIOC_QBUF);
    printf("VIDIOC_DQBUF = 0x%x\n", VIDIOC_DQBUF);
    printf("VIDIOC_STREAMON = 0x%x\n", VIDIOC_STREAMON);
    printf("PROT_READ = 0x%x\n", PROT_READ);
    printf("PROT_WRITE = 0x%x\n", PROT_WRITE);
    printf("MAP_SHARED = 0x%x\n", MAP_SHARED);
    printf("MAP_FAILED = 0x%x\n", MAP_FAILED);
    return 0;
}
