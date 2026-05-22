#include "overlay.h"
#include <fontconfig/fontconfig.h>
#include <string.h>
#include <math.h>

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_move_to(cr, x + r, y);
    cairo_line_to(cr, x + w - r, y);
    cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
    cairo_line_to(cr, x + w, y + h - r);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
    cairo_line_to(cr, x + r, y + h);
    cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
    cairo_line_to(cr, x, y + r);
    cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
    cairo_close_path(cr);
}

static void set_font(cairo_t *cr, double size) {
    cairo_select_font_face(cr, "Roboto", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL);
    cairo_set_font_size(cr, size);
}

static void draw_pill_text(cairo_t *cr, double x, double y, double w, double h,
                           const char *line1, const char *line2) {
    cairo_save(cr);
    rounded_rect(cr, x, y, w, h, 12.0);
    cairo_set_source_rgba(cr, 0, 0, 0, 0.55);
    cairo_fill(cr);

    set_font(cr, 16.0);
    cairo_set_source_rgba(cr, 1, 1, 1, 0.9);

    if (line1 && line2) {
        cairo_move_to(cr, x + 12, y + h / 2 - 2);
        cairo_show_text(cr, line1);
        cairo_move_to(cr, x + 12, y + h / 2 + 18);
        cairo_show_text(cr, line2);
    } else if (line1) {
        cairo_move_to(cr, x + 12, y + h / 2 + 7);
        cairo_show_text(cr, line1);
    }

    cairo_restore(cr);
}

void fc_init_fonts(void) {
    FcConfig *cfg = FcInitLoadConfigAndFonts();
    FcConfigParseAndLoad(cfg, (FcChar8 *)"/app/priv/fonts/fonts.conf", FcFalse);
    FcConfigAppFontAddFile(cfg, (FcChar8 *)"/app/priv/fonts/Roboto-Regular.ttf");
    FcConfigSetCurrent(cfg);
}

void draw_overlays(cairo_t *cr, int width, int height, const overlay_params_t *params) {
    double pill_w = 200.0;
    double pill_h = 60.0;
    double margin = 16.0;

    if (params->temp || params->condition) {
        draw_pill_text(cr,
                       width - pill_w - margin,
                       height - pill_h - margin,
                       pill_w, pill_h,
                       params->temp, params->condition);
    }

    if (params->date || params->location) {
        draw_pill_text(cr,
                       margin,
                       height - pill_h - margin,
                       pill_w, pill_h,
                       params->date, params->location);
    }

    if (params->show_disconnected) {
        const char *msg = "Reconnecting...";
        cairo_text_extents_t ext;
        cairo_save(cr);
        set_font(cr, 18.0);
        cairo_text_extents(cr, msg, &ext);
        double bw = ext.width + 32;
        double bh = 40.0;
        double bx = (width - bw) / 2.0;
        double by = margin;
        rounded_rect(cr, bx, by, bw, bh, 10.0);
        cairo_set_source_rgba(cr, 0.8, 0.5, 0, 0.85);
        cairo_fill(cr);
        cairo_set_source_rgba(cr, 1, 1, 1, 1);
        cairo_move_to(cr, bx + 16, by + bh / 2 + 7);
        cairo_show_text(cr, msg);
        cairo_restore(cr);
    }

    if (params->show_empty_album) {
        const char *msg = "No photos found in album";
        cairo_text_extents_t ext;
        cairo_save(cr);
        set_font(cr, 20.0);
        cairo_text_extents(cr, msg, &ext);
        cairo_set_source_rgba(cr, 1, 1, 1, 0.8);
        cairo_move_to(cr, (width - ext.width) / 2.0, height / 2.0);
        cairo_show_text(cr, msg);
        cairo_restore(cr);
    }

    if (params->debug) {
        double bar_h = 28.0;
        cairo_save(cr);
        cairo_rectangle(cr, 0, height - bar_h, width, bar_h);
        cairo_set_source_rgba(cr, 0, 0, 0, 0.6);
        cairo_fill(cr);
        set_font(cr, 14.0);
        cairo_set_source_rgba(cr, 0.7, 1, 0.7, 1);
        cairo_move_to(cr, 8, height - 8);
        cairo_show_text(cr, params->debug);
        cairo_restore(cr);
    }
}
