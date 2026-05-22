#include "display.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

typedef struct {
    uint32_t handle;
    uint32_t fb_id;
    void *map;
    size_t size;
} drm_buf_t;

typedef struct {
    int fd;
    drmModeCrtc *crtc;
    uint32_t connector_id;
    drmModeModeInfo mode;
    drm_buf_t bufs[2];
    int front;
} drm_priv_t;

static int create_dumb_buf(int fd, uint32_t width, uint32_t height, drm_buf_t *buf) {
    struct drm_mode_create_dumb creq = {0};
    creq.width = width;
    creq.height = height;
    creq.bpp = 32;

    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        fprintf(stderr, "drm: DRM_IOCTL_MODE_CREATE_DUMB failed\n");
        return -1;
    }

    buf->handle = creq.handle;
    buf->size = creq.size;

    if (drmModeAddFB(fd, width, height, 24, 32, creq.pitch, creq.handle, &buf->fb_id) < 0) {
        fprintf(stderr, "drm: drmModeAddFB failed\n");
        return -1;
    }

    struct drm_mode_map_dumb mreq = {0};
    mreq.handle = creq.handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
        fprintf(stderr, "drm: DRM_IOCTL_MODE_MAP_DUMB failed\n");
        return -1;
    }

    buf->map = mmap(NULL, buf->size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
    if (buf->map == MAP_FAILED) {
        fprintf(stderr, "drm: mmap dumb buffer failed\n");
        return -1;
    }

    memset(buf->map, 0, buf->size);
    return 0;
}

static void drm_blit(display_backend_t *self, cairo_surface_t *surface) {
    drm_priv_t *priv = (drm_priv_t *)self->priv;
    int back = 1 - priv->front;
    drm_buf_t *buf = &priv->bufs[back];

    cairo_surface_flush(surface);
    unsigned char *src = cairo_image_surface_get_data(surface);
    int src_stride = cairo_image_surface_get_stride(surface);
    int dst_stride = self->width * 4;

    for (int y = 0; y < (int)self->height; y++) {
        memcpy((char *)buf->map + y * dst_stride, src + y * src_stride, dst_stride);
    }

    if (drmModePageFlip(priv->fd, priv->crtc->crtc_id, buf->fb_id,
                        DRM_MODE_PAGE_FLIP_EVENT, NULL) < 0) {
        drmModeSetCrtc(priv->fd, priv->crtc->crtc_id, buf->fb_id, 0, 0,
                       &priv->connector_id, 1, &priv->mode);
    } else {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(priv->fd, &fds);
        struct timeval tv = { 1, 0 };
        select(priv->fd + 1, &fds, NULL, NULL, &tv);
        drmHandleEvent(priv->fd, &(drmEventContext){ .version = 2 });
    }

    priv->front = back;
}

static void destroy_dumb_buf(int fd, drm_buf_t *buf) {
    if (buf->map && buf->map != MAP_FAILED) munmap(buf->map, buf->size);
    if (buf->fb_id) drmModeRmFB(fd, buf->fb_id);
    if (buf->handle) {
        struct drm_mode_destroy_dumb dreq = { .handle = buf->handle };
        drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
    }
}

static void drm_close(display_backend_t *self) {
    drm_priv_t *priv = (drm_priv_t *)self->priv;
    if (priv->crtc) {
        drmModeSetCrtc(priv->fd, priv->crtc->crtc_id,
                       priv->crtc->buffer_id, priv->crtc->x, priv->crtc->y,
                       &priv->connector_id, 1, &priv->crtc->mode);
        drmModeFreeCrtc(priv->crtc);
    }
    destroy_dumb_buf(priv->fd, &priv->bufs[0]);
    destroy_dumb_buf(priv->fd, &priv->bufs[1]);
    if (priv->fd >= 0) close(priv->fd);
    free(priv);
    free(self);
}

display_backend_t *display_open_drm(void) {
    int fd = open("/dev/dri/card0", O_RDWR);
    if (fd < 0) {
        if (errno != ENOENT && errno != ENODEV)
            fprintf(stderr, "drm: cannot open /dev/dri/card0: %m\n");
        return NULL;
    }

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) {
        fprintf(stderr, "drm: drmModeGetResources failed\n");
        close(fd);
        return NULL;
    }

    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) {
            conn = c;
            break;
        }
        if (c) drmModeFreeConnector(c);
    }

    if (!conn) {
        fprintf(stderr, "drm: no connected connector found\n");
        drmModeFreeResources(res);
        close(fd);
        return NULL;
    }

    drmModeEncoder *enc = NULL;
    if (conn->encoder_id)
        enc = drmModeGetEncoder(fd, conn->encoder_id);

    drmModeCrtc *crtc = NULL;
    if (enc && enc->crtc_id)
        crtc = drmModeGetCrtc(fd, enc->crtc_id);

    if (!crtc) {
        for (int i = 0; i < res->count_crtcs; i++) {
            crtc = drmModeGetCrtc(fd, res->crtcs[i]);
            if (crtc) break;
        }
    }

    if (!crtc) {
        fprintf(stderr, "drm: no CRTC found\n");
        if (enc) drmModeFreeEncoder(enc);
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        close(fd);
        return NULL;
    }

    drmModeModeInfo mode = conn->modes[0];
    uint32_t width = mode.hdisplay;
    uint32_t height = mode.vdisplay;

    drm_priv_t *priv = calloc(1, sizeof(drm_priv_t));
    if (!priv) {
        drmModeFreeCrtc(crtc);
        if (enc) drmModeFreeEncoder(enc);
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        close(fd);
        return NULL;
    }

    priv->fd = fd;
    priv->crtc = crtc;
    priv->connector_id = conn->connector_id;
    priv->mode = mode;
    priv->front = 0;

    if (create_dumb_buf(fd, width, height, &priv->bufs[0]) < 0 ||
        create_dumb_buf(fd, width, height, &priv->bufs[1]) < 0) {
        destroy_dumb_buf(fd, &priv->bufs[0]);
        destroy_dumb_buf(fd, &priv->bufs[1]);
        drmModeFreeCrtc(crtc);
        if (enc) drmModeFreeEncoder(enc);
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        free(priv);
        close(fd);
        return NULL;
    }

    if (drmModeSetCrtc(fd, crtc->crtc_id, priv->bufs[0].fb_id, 0, 0,
                       &priv->connector_id, 1, &mode) < 0) {
        fprintf(stderr, "drm: drmModeSetCrtc failed\n");
        destroy_dumb_buf(fd, &priv->bufs[0]);
        destroy_dumb_buf(fd, &priv->bufs[1]);
        drmModeFreeCrtc(crtc);
        if (enc) drmModeFreeEncoder(enc);
        drmModeFreeConnector(conn);
        drmModeFreeResources(res);
        free(priv);
        close(fd);
        return NULL;
    }

    if (enc) drmModeFreeEncoder(enc);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);

    display_backend_t *d = malloc(sizeof(display_backend_t));
    if (!d) {
        destroy_dumb_buf(fd, &priv->bufs[0]);
        destroy_dumb_buf(fd, &priv->bufs[1]);
        drmModeFreeCrtc(crtc);
        free(priv);
        close(fd);
        return NULL;
    }
    d->width = width;
    d->height = height;
    d->blit = drm_blit;
    d->close = drm_close;
    d->priv = priv;
    return d;
}
