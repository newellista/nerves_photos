#include "render.h"
#include <cairo.h>
#include <math.h>

static void draw_slot(cairo_t *cr, cairo_surface_t *slot,
                      int disp_w, int disp_h, int crop_mode, double alpha) {
    if (!slot) {
        cairo_set_source_rgba(cr, 0, 0, 0, alpha);
        cairo_paint(cr);
        return;
    }

    int img_w = cairo_image_surface_get_width(slot);
    int img_h = cairo_image_surface_get_height(slot);

    double scale, dx, dy;
    if (crop_mode == CROP_CENTER) {
        scale = fmax((double)disp_w / img_w, (double)disp_h / img_h);
    } else {
        scale = fmin((double)disp_w / img_w, (double)disp_h / img_h);
    }

    double scaled_w = img_w * scale;
    double scaled_h = img_h * scale;
    dx = (disp_w - scaled_w) / 2.0;
    dy = (disp_h - scaled_h) / 2.0;

    cairo_save(cr);

    if (crop_mode == CROP_CENTER) {
        cairo_rectangle(cr, 0, 0, disp_w, disp_h);
        cairo_clip(cr);
    }

    cairo_translate(cr, dx, dy);
    cairo_scale(cr, scale, scale);
    cairo_set_source_surface(cr, slot, 0, 0);
    cairo_paint_with_alpha(cr, alpha);

    cairo_restore(cr);
}

void render_frame(
    cairo_surface_t *slots[2],
    display_backend_t *display,
    int transition_type,
    float t,
    int crop_mode,
    const overlay_params_t *overlays
) {
    int w = display->width;
    int h = display->height;

    cairo_surface_t *canvas = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, w, h);
    if (cairo_surface_status(canvas) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(canvas);
        return;
    }
    cairo_t *cr = cairo_create(canvas);

    cairo_set_source_rgb(cr, 0, 0, 0);
    cairo_paint(cr);

    if (transition_type == TRANSITION_NONE || t <= 0.0f) {
        draw_slot(cr, slots[0], w, h, crop_mode, 1.0);
    } else if (transition_type == TRANSITION_FADE_BLACK) {
        if (t < 0.5f) {
            draw_slot(cr, slots[0], w, h, crop_mode, 1.0);
            cairo_set_source_rgba(cr, 0, 0, 0, t * 2.0);
            cairo_paint(cr);
        } else {
            draw_slot(cr, slots[1], w, h, crop_mode, 1.0);
            cairo_set_source_rgba(cr, 0, 0, 0, (1.0f - t) * 2.0);
            cairo_paint(cr);
        }
    } else if (transition_type == TRANSITION_CROSS) {
        draw_slot(cr, slots[0], w, h, crop_mode, 1.0 - t);
        cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
        draw_slot(cr, slots[1], w, h, crop_mode, t);
    }

    if (overlays) draw_overlays(cr, w, h, overlays);

    cairo_destroy(cr);
    display->blit(display, canvas);
    cairo_surface_destroy(canvas);
}
