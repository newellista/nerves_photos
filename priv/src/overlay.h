#ifndef OVERLAY_H
#define OVERLAY_H

#include <cairo.h>

typedef struct {
    char *date;
    char *location;
    char *temp;
    char *condition;
    char *debug;
    int show_disconnected;
    int show_empty_album;
} overlay_params_t;

void fc_init_fonts(void);
void draw_overlays(cairo_t *cr, int width, int height, const overlay_params_t *params);

#endif
