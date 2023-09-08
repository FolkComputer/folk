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
                   0x00, shear*sprite.components);
        } else if (shear < 0) {
            memset(&sprite.data[y*sprite.bytesPerRow + (x0+width+shear)*sprite.components],
                   0x00, -shear*sprite.components);
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
                memmove(&sprite.data[to], &sprite.data[from], sprite.components);
                // Blot out the unsheared part
                if (from != to) { memset(&sprite.data[from], 0x00, sprite.components); }
            }
        }
    } else if (sy < 0) {
        for (int y = y0; y < y0 + height; y++) {
            for (int x = x0; x < x0 + width; x++) {
                int shear = sy * (x - x0); // Is negative.
                int from = y*sprite.bytesPerRow + x*sprite.components;
                int to = (y + shear)*sprite.bytesPerRow + x*sprite.components;
                memmove(&sprite.data[to], &sprite.data[from], sprite.components);
                // Blot out the unsheared part
                if (from != to) { memset(&sprite.data[from], 0x00, sprite.components); }
            }
        }
    }
}

dc proc rotate180 {image_t sprite int x0 int y0 int width int height} void {
    // In-place flip X and Y.
    int imin = y0*sprite.bytesPerRow + x0*sprite.components;
    int imax = (y0+height-1)*sprite.bytesPerRow + (x0+width-1)*sprite.components;
    int icenter = imin + (imax - imin)/2;
    for (int i = imin; i < icenter; i += sprite.components) {
        int j = imax - (i - imin);
        uint8_t temp[sprite.components]; memcpy(temp, &sprite.data[i], sprite.components);
        memmove(&sprite.data[i], &sprite.data[j], sprite.components);
        memcpy(&sprite.data[j], temp, sprite.components);
    }
}
dc proc rotateMakeImage {int width int height int components double radians
                         int* x0 int* y0} image_t {
    // Allocates and sets up an image with enough space to accommodate
    // the rotation.
    
    if (radians > M_PI/2 || radians < -M_PI/2) {
        if (radians > M_PI/2) radians -= M_PI;
        if (radians < -M_PI/2) radians += M_PI;
    }
    double alpha = -tan(-radians/2);
    double beta = sin(-radians);

    image_t ret;
    ret.width = width; 
    ret.height = height;

    ret.width += fabs(alpha)*ret.height;
    ret.height += fabs(beta)*ret.width;
    ret.width += fabs(alpha)*ret.height;

    ret.components = components;
    ret.bytesPerRow = ret.width * ret.components;
    ret.data = ckalloc(ret.bytesPerRow * ret.height);
    memset(ret.data, 0x00, ret.bytesPerRow * ret.height);

    *x0 = alpha > 0 ? 0 : ret.width - width;
    *y0 = beta > 0 ? 0 : ret.height - height;
    return ret;
}
dc proc rotate {image_t sprite int x0 int y0 int width int height double radians} void {
    // In-place rotation counterclockwise from the horizontal. Sprite
    // must be big enough to accommodate all shears.

    // radians should be between -pi/2 and pi/2 for good results.
    if (radians > M_PI/2 || radians < -M_PI/2) {
        rotate180(sprite, x0, y0, width, height);
        if (radians > M_PI/2) radians -= M_PI;
        if (radians < -M_PI/2) radians += M_PI;
    }
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
