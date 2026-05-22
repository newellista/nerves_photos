#include "display.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <cairo.h>

typedef struct {
    int fd;
    void *fb_mem;
    size_t fb_size;
    int bits_per_pixel;
} fbdev_priv_t;

static void fbdev_blit(display_backend_t *self, cairo_surface_t *surface) {
    fbdev_priv_t *priv = (fbdev_priv_t *)self->priv;
    int width = self->width;
    int height = self->height;

    cairo_surface_flush(surface);
    unsigned char *src = cairo_image_surface_get_data(surface);
    int src_stride = cairo_image_surface_get_stride(surface);

    if (priv->bits_per_pixel == 32) {
        unsigned char *dst = (unsigned char *)priv->fb_mem;
        int dst_stride = width * 4;
        for (int y = 0; y < height; y++) {
            memcpy(dst + y * dst_stride, src + y * src_stride, width * 4);
        }
    } else if (priv->bits_per_pixel == 16) {
        uint16_t *dst = (uint16_t *)priv->fb_mem;
        for (int y = 0; y < height; y++) {
            uint32_t *row = (uint32_t *)(src + y * src_stride);
            for (int x = 0; x < width; x++) {
                uint32_t pix = row[x];
                uint8_t r = (pix >> 16) & 0xFF;
                uint8_t g = (pix >> 8) & 0xFF;
                uint8_t b = pix & 0xFF;
                dst[y * width + x] = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
            }
        }
    }
}

static void fbdev_close(display_backend_t *self) {
    fbdev_priv_t *priv = (fbdev_priv_t *)self->priv;
    if (priv->fb_mem && priv->fb_mem != MAP_FAILED)
        munmap(priv->fb_mem, priv->fb_size);
    if (priv->fd >= 0) close(priv->fd);
    free(priv);
    free(self);
}

display_backend_t *display_open_fbdev(void) {
    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) {
        fprintf(stderr, "fbdev: cannot open /dev/fb0\n");
        return NULL;
    }

    struct fb_var_screeninfo vinfo;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
        fprintf(stderr, "fbdev: FBIOGET_VSCREENINFO failed\n");
        close(fd);
        return NULL;
    }

    int width = vinfo.xres;
    int height = vinfo.yres;
    int bpp = vinfo.bits_per_pixel;
    size_t fb_size = width * height * (bpp / 8);

    void *fb_mem = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (fb_mem == MAP_FAILED) {
        fprintf(stderr, "fbdev: mmap failed\n");
        close(fd);
        return NULL;
    }

    fbdev_priv_t *priv = malloc(sizeof(fbdev_priv_t));
    if (!priv) {
        munmap(fb_mem, fb_size);
        close(fd);
        return NULL;
    }
    priv->fd = fd;
    priv->fb_mem = fb_mem;
    priv->fb_size = fb_size;
    priv->bits_per_pixel = bpp;

    display_backend_t *d = malloc(sizeof(display_backend_t));
    if (!d) {
        munmap(fb_mem, fb_size);
        close(fd);
        free(priv);
        return NULL;
    }
    d->width = width;
    d->height = height;
    d->blit = fbdev_blit;
    d->close = fbdev_close;
    d->priv = priv;
    return d;
}
