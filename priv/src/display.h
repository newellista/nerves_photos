#ifndef DISPLAY_H
#define DISPLAY_H

#include <cairo.h>
#include <stdint.h>

typedef struct display_backend {
    uint32_t width;
    uint32_t height;
    void (*blit)(struct display_backend *self, cairo_surface_t *surface);
    void (*close)(struct display_backend *self);
    void *priv;
} display_backend_t;

display_backend_t *display_open_auto(void);
display_backend_t *display_open_fbdev(void);
#ifdef HAVE_DRM
display_backend_t *display_open_drm(void);
#endif

#endif
