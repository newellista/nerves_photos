#ifndef RENDER_H
#define RENDER_H

#include <cairo.h>
#include "display.h"
#include "overlay.h"

#define TRANSITION_NONE         0
#define TRANSITION_FADE_BLACK   1
#define TRANSITION_CROSS        2

#define CROP_LETTERBOX  0
#define CROP_CENTER     1

void render_frame(
    cairo_surface_t *slots[2],
    display_backend_t *display,
    int transition_type,
    float t,
    int crop_mode,
    const overlay_params_t *overlays
);

#endif
