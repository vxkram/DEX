// DEX's narrow interface to libjpeg-turbo: header facts and lossless
// (DCT-domain) transforms. libjpeg reports errors with longjmp, which Swift
// can't cross, so everything is wrapped in C and returns 0 on failure with
// a message in `error`.
#ifndef DEX_CJPEGTURBO_H
#define DEX_CJPEGTURBO_H

#include <stddef.h>

typedef struct {
    unsigned width;
    unsigned height;
    int components;
    /// Size of one iMCU in pixels: lossless crops must start on multiples.
    unsigned mcu_width;
    unsigned mcu_height;
    int progressive;
} dx_jpeg_info;

typedef struct {
    int crop;
    unsigned crop_x, crop_y, crop_width, crop_height;
    /// Huffman-optimised output: smaller, still lossless.
    int optimize;
    int progressive;
} dx_jpeg_options;

int dx_jpeg_read_info(const unsigned char *data, size_t size, dx_jpeg_info *info,
                      char *error, size_t error_size);

/// Crops (and optimises) without decoding pixels. Only ICC profile markers
/// are carried over; other metadata is rewritten by ImageIO afterwards.
/// On success `*output` must be released with dx_jpeg_free.
int dx_jpeg_transform(const unsigned char *data, size_t size, const dx_jpeg_options *options,
                      unsigned char **output, size_t *output_size, char *error, size_t error_size);

void dx_jpeg_free(unsigned char *buffer);

#endif
