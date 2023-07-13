# This file implements rotation in software using three shears.
#
# See:
# - https://cohost.org/tomforsyth/post/891823-rotation-with-three
# - https://www.ocf.berkeley.edu/~fricke/projects/israel/paeth/rotation_by_shearing.html
# - http://www.leptonica.org/rotation.html

dc proc shearX {image_t sprite int x0 int y0 int width int height double sx} void {
    for (int y = y0; y < y0 + height; y++) {
        int shear = sx * (y - y0); // May be negative.
        memmove(&sprite.data[y*sprite.bytesPerRow + (x0 + shear)*sprite.components],
                &sprite.data[y*sprite.bytesPerRow + x0*sprite.components],
                width * sprite.components);

        // Blot out the unsheared part
        if (shear > 0) {
            memset(&sprite.data[y*sprite.bytesPerRow + x0*sprite.components],
                   0x11, shear*sprite.components);
        } else if (shear < 0) {
            memset(&sprite.data[y*sprite.bytesPerRow + (x0+width+shear)*sprite.components],
                   0x11, -shear*sprite.components);
        }
    }
}
dc proc shearY {image_t sprite int x0 int y0 int width int height double sy} void {
    if (sy > 0) {
        for (int y = y0 + height - 1; y >= y0; y--) {
            for (int x = x0; x < x0 + width; x++) {
                int shear = sy * (x - x0);
                int from = y*sprite.bytesPerRow + x*sprite.components;
                int to = (y + shear)*sprite.bytesPerRow + x*sprite.components;
                sprite.data[to] = sprite.data[from];
                // Blot out the unsheared part
                if (from != to) { sprite.data[from] = 0x11; }
            }
        }
    } else if (sy < 0) {
        for (int y = y0; y < y0 + height; y++) {
            for (int x = x0; x < x0 + width; x++) {
                int shear = sy * (x - x0); // Is negative.
                int from = y*sprite.bytesPerRow + x*sprite.components;
                int to = (y + shear)*sprite.bytesPerRow + x*sprite.components;
                sprite.data[to] = sprite.data[from];
                // Blot out the unsheared part
                if (from != to) { sprite.data[from] = 0x11; }
            }
        }
    }
}
# dc proc rotate180 {image_t sprite int x0 int y0 int width int height} void {
#     // In-place flip X and Y.
#     for (int y = y0; y < y0 + height; y++) {
#         for (int x = x0; x < x0 + width; x++) {
#             int from = y*sprite.bytesPerRow + x*sprite.components;
#             int to = *sprite.bytesPerRow + x*sprite.components;
#         }
#     }
# }
dc proc rotate {image_t sprite int x0 int y0 int width int height double radians} void {
    // In-place rotation counterclockwise from the horizontal. Sprite
    // must be big enough to accommodate all shears.

    // FIXME: rotate180

    // radians should be between -pi/2 and pi/2 for good results.
    double alpha = -tan(-radians/2);
    double beta = sin(-radians);

    shearX(sprite, x0, y0, width, height, alpha);
    if (alpha < 0) x0 += alpha*height;
    width += fabs(alpha)*height;

    shearY(sprite, x0, y0, width, height, beta);
    if (beta < 0) y0 += beta*width;
    height += fabs(beta)*width;

    shearX(sprite, x0, y0, width, height, alpha);
}
