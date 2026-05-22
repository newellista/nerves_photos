#include "image.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <setjmp.h>
#include <jpeglib.h>
#include <png.h>

struct jpeg_err_ext {
    struct jpeg_error_mgr pub;
    jmp_buf jb;
};

static void jpeg_error_exit_safe(j_common_ptr cinfo) {
    longjmp(((struct jpeg_err_ext *)cinfo->err)->jb, 1);
}

static int is_jpeg(const uint8_t *data, uint32_t len) {
    return len >= 2 && data[0] == 0xFF && data[1] == 0xD8;
}

static int is_png(const uint8_t *data, uint32_t len) {
    static const uint8_t png_sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    return len >= 8 && memcmp(data, png_sig, 8) == 0;
}

static cairo_surface_t *decode_jpeg(const uint8_t *data, uint32_t len) {
    struct jpeg_decompress_struct cinfo;
    struct jpeg_err_ext jerr;

    cinfo.err = jpeg_std_error(&jerr.pub);
    jerr.pub.error_exit = jpeg_error_exit_safe;
    jpeg_create_decompress(&cinfo);
    if (setjmp(jerr.jb)) {
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }
    jpeg_mem_src(&cinfo, data, len);

    if (jpeg_read_header(&cinfo, TRUE) != JPEG_HEADER_OK) {
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }

    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);

    int width = cinfo.output_width;
    int height = cinfo.output_height;

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }

    unsigned char *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    uint8_t *row = malloc(width * 3);
    if (!row) {
        cairo_surface_destroy(surface);
        jpeg_destroy_decompress(&cinfo);
        return NULL;
    }

    cairo_surface_flush(surface);
    while ((int)cinfo.output_scanline < height) {
        jpeg_read_scanlines(&cinfo, &row, 1);
        int y = cinfo.output_scanline - 1;
        uint32_t *dst = (uint32_t *)(pixels + y * stride);
        for (int x = 0; x < width; x++) {
            uint8_t r = row[x * 3 + 0];
            uint8_t g = row[x * 3 + 1];
            uint8_t b = row[x * 3 + 2];
            dst[x] = (0xFF << 24) | (r << 16) | (g << 8) | b;
        }
    }

    free(row);
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    cairo_surface_mark_dirty(surface);
    return surface;
}

typedef struct {
    const uint8_t *data;
    uint32_t len;
    uint32_t pos;
} png_mem_src_t;

static void png_mem_read(png_structp png, png_bytep buf, png_size_t size) {
    png_mem_src_t *src = (png_mem_src_t *)png_get_io_ptr(png);
    if (src->pos + size > src->len) {
        png_error(png, "read past end of PNG buffer");
        return;
    }
    memcpy(buf, src->data + src->pos, size);
    src->pos += size;
}

static cairo_surface_t *decode_png(const uint8_t *data, uint32_t len) {
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png) return NULL;

    png_infop info = png_create_info_struct(png);
    if (!info) {
        png_destroy_read_struct(&png, NULL, NULL);
        return NULL;
    }

    if (setjmp(png_jmpbuf(png))) {
        png_destroy_read_struct(&png, &info, NULL);
        return NULL;
    }

    png_mem_src_t src = { data, len, 0 };
    png_set_read_fn(png, &src, png_mem_read);
    png_read_info(png, info);

    int width = png_get_image_width(png, info);
    int height = png_get_image_height(png, info);
    png_byte color_type = png_get_color_type(png, info);
    png_byte bit_depth = png_get_bit_depth(png, info);

    if (bit_depth == 16) png_set_strip_16(png);
    if (color_type == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (color_type == PNG_COLOR_TYPE_RGB || color_type == PNG_COLOR_TYPE_GRAY ||
        color_type == PNG_COLOR_TYPE_PALETTE) {
        png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    }
    if (color_type == PNG_COLOR_TYPE_GRAY || color_type == PNG_COLOR_TYPE_GRAY_ALPHA) {
        png_set_gray_to_rgb(png);
    }

    png_read_update_info(png, info);

    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        png_destroy_read_struct(&png, &info, NULL);
        return NULL;
    }

    unsigned char *pixels = cairo_image_surface_get_data(surface);
    int stride = cairo_image_surface_get_stride(surface);
    uint8_t *row = malloc(png_get_rowbytes(png, info));
    if (!row) {
        cairo_surface_destroy(surface);
        png_destroy_read_struct(&png, &info, NULL);
        return NULL;
    }

    cairo_surface_flush(surface);
    for (int y = 0; y < height; y++) {
        png_read_row(png, row, NULL);
        uint32_t *dst = (uint32_t *)(pixels + y * stride);
        for (int x = 0; x < width; x++) {
            uint8_t r = row[x * 4 + 0];
            uint8_t g = row[x * 4 + 1];
            uint8_t b = row[x * 4 + 2];
            uint8_t a = row[x * 4 + 3];
            /* premultiply alpha for CAIRO_FORMAT_ARGB32 */
            dst[x] = ((uint32_t)a << 24) |
                     ((uint32_t)(r * a / 255) << 16) |
                     ((uint32_t)(g * a / 255) << 8) |
                     (uint32_t)(b * a / 255);
        }
    }

    free(row);
    png_destroy_read_struct(&png, &info, NULL);
    cairo_surface_mark_dirty(surface);
    return surface;
}

cairo_surface_t *decode_image(const uint8_t *data, uint32_t len) {
    if (is_jpeg(data, len)) return decode_jpeg(data, len);
    if (is_png(data, len)) return decode_png(data, len);
    return NULL;
}

void free_image(cairo_surface_t *surface) {
    if (surface) cairo_surface_destroy(surface);
}
