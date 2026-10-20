#include "../include/CJPEGTurbo.h"

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jpeglib.h"
#include "transupp.h"

typedef struct {
    struct jpeg_error_mgr base;
    jmp_buf jump;
    char *message;
    size_t message_size;
} dx_error;

static void dx_error_exit(j_common_ptr cinfo) {
    dx_error *err = (dx_error *)cinfo->err;
    if (err->message && err->message_size) {
        (*cinfo->err->format_message)(cinfo, err->message);
    }
    longjmp(err->jump, 1);
}

static void dx_silence(j_common_ptr cinfo) { (void)cinfo; }

static void dx_set_error(char *error, size_t size, const char *text) {
    if (error && size) snprintf(error, size, "%s", text);
}

static void dx_install_errors(dx_error *err, char *error, size_t error_size) {
    jpeg_std_error(&err->base);
    err->base.error_exit = dx_error_exit;
    err->base.output_message = dx_silence;
    err->message = error;
    err->message_size = error_size >= JMSG_LENGTH_MAX ? error_size : 0;
}

int dx_jpeg_read_info(const unsigned char *data, size_t size, dx_jpeg_info *info,
                      char *error, size_t error_size) {
    struct jpeg_decompress_struct src;
    dx_error err;
    dx_install_errors(&err, error, error_size);
    src.err = &err.base;
    if (setjmp(err.jump)) {
        jpeg_destroy_decompress(&src);
        return 0;
    }
    jpeg_create_decompress(&src);
    jpeg_mem_src(&src, data, (unsigned long)size);
    jpeg_read_header(&src, TRUE);

    info->width = src.image_width;
    info->height = src.image_height;
    info->components = src.num_components;
    // Single-component images use 8×8 blocks regardless of sampling factors.
    int h = src.num_components == 1 ? 1 : src.max_h_samp_factor;
    int v = src.num_components == 1 ? 1 : src.max_v_samp_factor;
    info->mcu_width = (unsigned)(h * DCTSIZE);
    info->mcu_height = (unsigned)(v * DCTSIZE);
    info->progressive = src.progressive_mode ? 1 : 0;
    jpeg_destroy_decompress(&src);
    return 1;
}

static int dx_is_icc_marker(jpeg_saved_marker_ptr marker) {
    static const char signature[] = "ICC_PROFILE";  // includes the NUL
    return marker->marker == JPEG_APP0 + 2 && marker->data_length >= sizeof(signature) &&
           memcmp(marker->data, signature, sizeof(signature)) == 0;
}

int dx_jpeg_transform(const unsigned char *data, size_t size, const dx_jpeg_options *options,
                      unsigned char **output, size_t *output_size, char *error, size_t error_size) {
    struct jpeg_decompress_struct src;
    struct jpeg_compress_struct dst;
    dx_error err;
    unsigned char *buffer = NULL;
    unsigned long buffer_size = 0;
    int created_dst = 0;

    *output = NULL;
    *output_size = 0;
    dx_install_errors(&err, error, error_size);
    src.err = &err.base;
    dst.err = &err.base;
    if (setjmp(err.jump)) {
        if (created_dst) jpeg_destroy_compress(&dst);
        jpeg_destroy_decompress(&src);
        free(buffer);
        return 0;
    }

    jpeg_create_decompress(&src);
    jpeg_create_compress(&dst);
    created_dst = 1;
    jpeg_mem_src(&src, data, (unsigned long)size);
    // Keep APP2 so ICC profiles survive; MPF (also APP2) is filtered below
    // because the images it points to (e.g. gain maps) are not carried over.
    jpeg_save_markers(&src, JPEG_APP0 + 2, 0xFFFF);
    jpeg_read_header(&src, TRUE);

    jpeg_transform_info transform;
    memset(&transform, 0, sizeof(transform));
    transform.transform = JXFORM_NONE;
    if (options->crop) {
        char spec[96];
        snprintf(spec, sizeof(spec), "%ux%u+%u+%u", options->crop_width, options->crop_height,
                 options->crop_x, options->crop_y);
        if (!jtransform_parse_crop_spec(&transform, spec)) {
            dx_set_error(error, error_size, "invalid crop rectangle");
            jpeg_destroy_compress(&dst);
            jpeg_destroy_decompress(&src);
            return 0;
        }
    }
    if (!jtransform_request_workspace(&src, &transform)) {
        dx_set_error(error, error_size, "this transform is not possible losslessly");
        jpeg_destroy_compress(&dst);
        jpeg_destroy_decompress(&src);
        return 0;
    }

    jvirt_barray_ptr *src_coefficients = jpeg_read_coefficients(&src);
    jpeg_copy_critical_parameters(&src, &dst);
    jvirt_barray_ptr *dst_coefficients =
        jtransform_adjust_parameters(&src, &dst, src_coefficients, &transform);
    dst.optimize_coding = options->optimize ? TRUE : FALSE;
    if (options->progressive) jpeg_simple_progression(&dst);

    jpeg_mem_dest(&dst, &buffer, &buffer_size);
    jpeg_write_coefficients(&dst, dst_coefficients);
    if (options->exif_orientation > 1 && options->exif_orientation <= 8) {
        // "Exif\0\0", big-endian TIFF header, one IFD entry: Orientation
        // (0x0112), SHORT, count 1, value; no next IFD. 32 bytes.
        const JOCTET exif[32] = {
            'E', 'x', 'i', 'f', 0, 0,
            'M', 'M', 0, 42, 0, 0, 0, 8,
            0, 1,
            0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, (JOCTET)options->exif_orientation, 0, 0,
            0, 0, 0, 0,
        };
        jpeg_write_marker(&dst, JPEG_APP0 + 1, exif, sizeof(exif));
    }
    for (jpeg_saved_marker_ptr marker = src.marker_list; marker; marker = marker->next) {
        if (dx_is_icc_marker(marker)) {
            jpeg_write_marker(&dst, marker->marker, marker->data, marker->data_length);
        }
    }
    jtransform_execute_transform(&src, &dst, src_coefficients, &transform);
    jpeg_finish_compress(&dst);
    jpeg_destroy_compress(&dst);
    created_dst = 0;
    (void)jpeg_finish_decompress(&src);
    jpeg_destroy_decompress(&src);

    *output = buffer;
    *output_size = buffer_size;
    return 1;
}

void dx_jpeg_free(unsigned char *buffer) { free(buffer); }
