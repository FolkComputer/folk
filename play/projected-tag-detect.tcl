puts hello

source pi/AprilTags.tcl
proc When {args} {}
source virtual-programs/images.folk


set cc [c create]
::defineImageType $cc
$cc include <stdlib.h>
$cc proc rgbToGray {image_t rgb} image_t {
    uint8_t* gray = calloc(rgb.width * rgb.height, sizeof (uint8_t));
    for (int y = 0; y < rgb.height; y++) {
        for (int x = 0; x < rgb.width; x++) {
            // we're spending 10-20% of camera time here on Pi ... ??

            int i = (y * rgb.width + x) * 3;
            uint32_t r = rgb.data[i];
            uint32_t g = rgb.data[i + 1];
            uint32_t b = rgb.data[i + 2];
            // from https://mina86.com/2021/rgb-to-greyscale/
            uint32_t yy = 3567664 * r + 11998547 * g + 1211005 * b;
            gray[y * rgb.width + x] = ((yy + (1 << 23)) >> 24);
        }
    }
    return (image_t) {
        .width = rgb.width, .height = rgb.height,
        .components = 1,
        .bytesPerRow = rgb.width,
        .data = gray
    };
}
$cc compile

set detector [AprilTags new "tagStandard52h13"]
set im [rgbToGray [image loadJpeg "frame-image-2.jpeg"]]
puts [$detector detect $im]
