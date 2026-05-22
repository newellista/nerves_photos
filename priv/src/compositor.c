#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <arpa/inet.h>
#include "protocol.h"
#include "image.h"
#include "display.h"
#include "render.h"
#include "overlay.h"

static display_backend_t *g_display = NULL;
static cairo_surface_t *g_slots[2] = {NULL, NULL};

static char *parse_str(const uint8_t *buf, int total, int *pos) {
    if (*pos >= total) return NULL;
    uint8_t slen = buf[*pos];
    (*pos)++;
    if (slen == 0) return NULL;
    if (*pos + slen > total) return NULL;
    char *s = malloc(slen + 1);
    if (!s) return NULL;
    memcpy(s, buf + *pos, slen);
    s[slen] = '\0';
    *pos += slen;
    return s;
}

static void handle_init(const uint8_t *buf, int len) {
    if (len < 6) { write_error(ERR_BAD_PAYLOAD, "init: short"); return; }
    uint16_t w, h;
    memcpy(&w, buf + 1, 2); w = ntohs(w);
    memcpy(&h, buf + 3, 2); h = ntohs(h);
    uint8_t mode = buf[5];

    if (g_display) { g_display->close(g_display); g_display = NULL; }

    if (mode == 1) g_display = display_open_fbdev();
    else if (mode == 2) g_display = display_open_drm();
    else g_display = display_open_auto();

    if (!g_display) { write_error(ERR_DISPLAY_FAILED, "display open failed"); return; }

    g_display->width = w;
    g_display->height = h;

    write_ok();
}

static void handle_load_image(const uint8_t *buf, int len) {
    if (!g_display) { write_error(ERR_NOT_INIT, "not initialized"); return; }
    if (len < 6) { write_error(ERR_BAD_PAYLOAD, "load: short"); return; }

    uint8_t slot_id = buf[1];
    if (slot_id > 1) { write_error(ERR_BAD_PAYLOAD, "bad slot"); return; }

    uint32_t byte_count;
    memcpy(&byte_count, buf + 2, 4);
    byte_count = ntohl(byte_count);

    if ((uint32_t)(len - 6) < byte_count) { write_error(ERR_BAD_PAYLOAD, "load: truncated"); return; }

    cairo_surface_t *surface = decode_image(buf + 6, byte_count);
    if (!surface) { write_error(ERR_DECODE_FAILED, "decode failed"); return; }

    if (g_slots[slot_id]) free_image(g_slots[slot_id]);
    g_slots[slot_id] = surface;

    uint16_t w16 = htons((uint16_t)cairo_image_surface_get_width(surface));
    uint16_t h16 = htons((uint16_t)cairo_image_surface_get_height(surface));
    uint8_t out[6];
    out[0] = RESP_IMAGE_LOADED;
    out[1] = slot_id;
    memcpy(out + 2, &w16, 2);
    memcpy(out + 4, &h16, 2);
    write_response(out, 6);
}

static void handle_free_slot(const uint8_t *buf, int len) {
    if (len < 2) { write_error(ERR_BAD_PAYLOAD, "free: short"); return; }
    uint8_t slot_id = buf[1];
    if (slot_id > 1) { write_error(ERR_BAD_PAYLOAD, "bad slot"); return; }
    if (g_slots[slot_id]) {
        free_image(g_slots[slot_id]);
        g_slots[slot_id] = NULL;
    }
    write_ok();
}

static void handle_render_frame(const uint8_t *buf, int len) {
    if (!g_display) { write_error(ERR_NOT_INIT, "not initialized"); return; }
    if (len < 7) { write_error(ERR_BAD_PAYLOAD, "render: short"); return; }

    int transition_type = buf[1];

    uint32_t ti;
    memcpy(&ti, buf + 2, 4);
    ti = ntohl(ti);
    float t;
    memcpy(&t, &ti, 4);

    int crop_mode = buf[6];
    uint8_t flags = (len > 7) ? buf[7] : 0;

    overlay_params_t overlays = {NULL, NULL, NULL, NULL, NULL, 0, 0};

    int pos = 8;

    if (flags & 0x01) {
        overlays.date     = parse_str(buf, len, &pos);
        overlays.location = parse_str(buf, len, &pos);
    }
    if (flags & 0x02) {
        overlays.temp      = parse_str(buf, len, &pos);
        overlays.condition = parse_str(buf, len, &pos);
    }
    if (flags & 0x04) {
        overlays.debug = parse_str(buf, len, &pos);
    }
    if (flags & 0x08) overlays.show_disconnected = 1;
    if (flags & 0x10) overlays.show_empty_album  = 1;

    render_frame(g_slots, g_display, transition_type, t, crop_mode, &overlays);

    free(overlays.date);
    free(overlays.location);
    free(overlays.temp);
    free(overlays.condition);
    free(overlays.debug);

    write_ok();
}

static void handle_get_dimensions(void) {
    if (!g_display) { write_error(ERR_NOT_INIT, "not initialized"); return; }
    uint16_t w16 = htons((uint16_t)g_display->width);
    uint16_t h16 = htons((uint16_t)g_display->height);
    uint8_t out[5];
    out[0] = RESP_DIMENSIONS;
    memcpy(out + 1, &w16, 2);
    memcpy(out + 3, &h16, 2);
    write_response(out, 5);
}

int main(void) {
    fc_init_fonts();

    uint8_t *buf;
    int len;

    while ((len = read_command(&buf)) != -1) {
        if (len < 1) { free(buf); continue; }

        uint8_t cmd = buf[0];
        switch (cmd) {
            case CMD_INIT:           handle_init(buf, len);          break;
            case CMD_LOAD_IMAGE:     handle_load_image(buf, len);    break;
            case CMD_FREE_SLOT:      handle_free_slot(buf, len);     break;
            case CMD_RENDER_FRAME:   handle_render_frame(buf, len);  break;
            case CMD_GET_DIMENSIONS: handle_get_dimensions();        break;
            case CMD_PING:           write_pong();                   break;
            default:                 write_error(ERR_UNKNOWN_CMD, "unknown command"); break;
        }

        free(buf);
    }

    if (g_display) g_display->close(g_display);
    return 0;
}
