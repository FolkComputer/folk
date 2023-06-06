source "lib/c.tcl"
set libpng [expr {$tcl_platform(os) eq "Darwin" ? "/opt/homebrew/lib/libpng.dylib" : [lindex [exec /usr/sbin/ldconfig -p | grep libpng] end]}]
c loadlib $libpng

set cc [c create]
$cc cflags -L[exec dirname $libpng] -lpng
$cc include <stdlib.h>
$cc include <png.h>
$cc code {
    typedef struct {
        uint16_t* columnCorr;
        uint16_t* rowCorr;
    } dense_t;
}

$cc proc remap {int x int x0 int x1 int y0 int y1} int {
  return y0 + (x - x0) * (y1 - y0) / (x1 - x0);
}
$cc proc loadDenseCorrespondenceFromPng {char* filename} dense_t* {
    FILE* src = fopen(filename, "rb");
    if (!src) { exit(1); }
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) { exit(1); }
    png_infop info = png_create_info_struct(png);
    if (!info) { exit(1); }
    if (setjmp(png_jmpbuf(png))) { exit(2); }
    png_init_io(png, src);
    png_read_info(png, info);

    int width      = png_get_image_width(png, info);
    int height     = png_get_image_height(png, info);
    // png_byte color_type = png_get_color_type(png, info);
    // png_byte bit_depth  = png_get_bit_depth(png, info);
    png_read_update_info(png, info);
    
    png_bytep* row_pointers = (png_bytep*)malloc(sizeof(png_bytep) * height);
    for(int y = 0; y < height; y++) {
        row_pointers[y] = (png_byte*)malloc(png_get_rowbytes(png, info));
    }
    png_read_image(png, row_pointers);
    fclose(src);
    png_destroy_read_struct(&png, &info, NULL);

    // TODO: Convert row_pointers to dense_t
    printf("Loaded with width %d and height %d\n", width, height);
    dense_t* dense = malloc(sizeof(dense_t));
    dense->rowCorr = calloc(width*height, sizeof(uint16_t));
    dense->columnCorr = calloc(width*height, sizeof(uint16_t));

    int rowCorrMin = 0;
    int rowCorrMax = 3935;
    int columnCorrMin = 0;
    int columnCorrMax = 4090;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            png_byte* pixel = &(row_pointers[y][x*4]);

            int i = y * width + x;
            dense->columnCorr[i] = remap(pixel[0], 0, 255, columnCorrMin, columnCorrMax);
            dense->rowCorr[i] = remap(pixel[1], 0, 255, rowCorrMin, rowCorrMax);
        }
    }
    return dense;
}

$cc proc serializeDenseCorrespondence {dense_t* dense char* filename} void [csubst {
    uint32_t width = 1920;
    uint32_t height = 1080;

    FILE* out = fopen(filename, "w");
    fwrite(&width, sizeof(uint32_t), 1, out);
    fwrite(&height, sizeof(uint32_t), 1, out);
    fwrite(dense->columnCorr, sizeof(uint16_t), width*height, out);
    fwrite(dense->rowCorr, sizeof(uint16_t), width*height, out);
    fclose(out);
}]

$cc proc writeDenseCorrespondenceToDisk {dense_t* dense char* filename} void [csubst {
  FILE* out = fopen(filename, "w");

  uint32_t width = 1920;
  uint32_t height = 1080;

  uint8_t* rgb = calloc(width * 3, height);

  int rowCorrMin = 32768;
  int rowCorrMax = -32768; 
  int columnCorrMin = 32768;
  int columnCorrMax = -32768; 

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int i = y * width + x;
      int v = dense->columnCorr[i];
      if (v == 0xFFFF) {
        // do nothing
      } else if (v < columnCorrMin) {
        columnCorrMin = v;
      } else if (v > columnCorrMax) {
        columnCorrMax = v;
      }
    }
  }

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int i = y * width + x;
      int v = dense->rowCorr[i];
      if (v == 0xFFFF) {
        // do nothing
      } else if (v < rowCorrMin) {
        rowCorrMin = v;
      } else if (v > rowCorrMax) {
        rowCorrMax = v;
      }
    }
  }

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int i = y * width + x;
      rgb[i*3] = (uint8_t)remap(dense->columnCorr[i], columnCorrMin, columnCorrMax, 0, 255);
      rgb[i*3 + 1] = (uint8_t)remap(dense->rowCorr[i], rowCorrMin, rowCorrMax, 0, 255);
      rgb[i*3 + 2] = 0;
    }
  }

  rgb_png(out, rgb, width, height, 100);
  fclose(out);
}]

$cc code {
    #include <png.h>

  void rgb_png(FILE* dest, uint8_t* rgb, uint32_t width, uint32_t height, int quality)
  {
      png_bytep* row_pointers = (png_bytep*) calloc(height, sizeof(png_bytep));
      for (size_t i = 0; i < height; i++) {
          row_pointers[i] = calloc(4 * width, sizeof(png_byte));
          for (size_t j = 0; j < width; j++) {
              row_pointers[i][j * 4 + 0] = rgb[(i * width + j) * 3 + 0];
              row_pointers[i][j * 4 + 1] = rgb[(i * width + j) * 3 + 1];
              row_pointers[i][j * 4 + 2] = rgb[(i * width + j) * 3 + 2];
              row_pointers[i][j * 4 + 3] = 255;
          }
      }

      png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
      if (!png_ptr) { exit(1); }

      png_infop info_ptr = png_create_info_struct(png_ptr);
      if (!info_ptr) { exit(1); }

      if (setjmp(png_jmpbuf(png_ptr))) { exit(2); }

      png_init_io(png_ptr, dest);
      png_set_IHDR(png_ptr, info_ptr, width, height,
                   8, PNG_COLOR_TYPE_RGBA, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_BASE, PNG_FILTER_TYPE_BASE);
      png_write_info(png_ptr, info_ptr);
      png_write_image(png_ptr, row_pointers);
      png_write_end(png_ptr, NULL);

      png_destroy_write_struct(&png_ptr, &info_ptr);
      for (size_t i = 0; i < height; i++) {
          free(row_pointers[i]);
      }
      free(row_pointers);
  }
}

$cc compile

set dense [loadDenseCorrespondenceFromPng [lindex $argv 0]]
serializeDenseCorrespondence $dense "blurred-dense.dense"
writeDenseCorrespondenceToDisk $dense "blurred-dense.png"
