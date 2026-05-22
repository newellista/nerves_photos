#include "display.h"

display_backend_t *display_open_auto(void) {
#ifdef HAVE_DRM
    display_backend_t *d = display_open_drm();
    if (d) return d;
#endif
    return display_open_fbdev();
}
