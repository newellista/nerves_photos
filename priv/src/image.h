#ifndef IMAGE_H
#define IMAGE_H

#include <cairo.h>
#include <stdint.h>

cairo_surface_t *decode_image(const uint8_t *data, uint32_t len);
void free_image(cairo_surface_t *surface);

#endif
