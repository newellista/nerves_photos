CC ?= gcc
PKG_CONFIG ?= pkg-config

# The darwin_arm Nerves toolchain sets PKG_CONFIG to a cross-pkg-config that
# doesn't exist. Fall back to the host pkg-config, which works correctly when
# PKG_CONFIG_LIBDIR and PKG_CONFIG_SYSROOT_DIR point at the Nerves sysroot.
ifeq ($(wildcard $(PKG_CONFIG)),)
PKG_CONFIG := pkg-config
endif

CFLAGS += -Wall -Wextra -Wno-unused-parameter -O2 -std=gnu99
CFLAGS += $(shell $(PKG_CONFIG) --cflags cairo 2>/dev/null)
CFLAGS += $(shell $(PKG_CONFIG) --cflags fontconfig 2>/dev/null)
CFLAGS += $(shell $(PKG_CONFIG) --cflags libjpeg 2>/dev/null)
CFLAGS += $(shell $(PKG_CONFIG) --cflags libpng 2>/dev/null)
LDFLAGS += $(shell $(PKG_CONFIG) --libs cairo 2>/dev/null)
LDFLAGS += $(shell $(PKG_CONFIG) --libs fontconfig 2>/dev/null)
LDFLAGS += $(shell $(PKG_CONFIG) --libs libjpeg 2>/dev/null)
LDFLAGS += $(shell $(PKG_CONFIG) --libs libpng 2>/dev/null)
LDFLAGS += -lm

# DRM backend is only available when libdrm is present in the sysroot (rpi4/rpi5).
# rpi3 uses fbdev only.
HAS_DRM := $(shell $(PKG_CONFIG) --exists libdrm 2>/dev/null && echo yes)
ifeq ($(HAS_DRM),yes)
CFLAGS  += $(shell $(PKG_CONFIG) --cflags libdrm 2>/dev/null) -DHAVE_DRM
LDFLAGS += $(shell $(PKG_CONFIG) --libs libdrm 2>/dev/null)
DRM_SRC  = display_drm.c
endif

SRCS = compositor.c protocol.c image.c display.c display_fbdev.c render.c overlay.c $(DRM_SRC)

# Use per-target object directories so rpi3 (armv7) and rpi5 (aarch64) objects
# don't collide when building multiple targets in the same worktree.
# Placed under _build/ (not priv/) so Nerves' scrub-otp-release.sh doesn't
# scan intermediate binaries for unexpected architectures.
OBJ_DIR    = ../../_build/.compositor_obj/$(if $(CROSSCOMPILE),$(notdir $(CROSSCOMPILE)),host)
OBJS       = $(addprefix $(OBJ_DIR)/,$(SRCS:.c=.o))
LINKED_BIN = $(OBJ_DIR)/compositor
TARGET     = ../../priv/compositor

ifeq ($(shell uname -s),Linux)
all: $(TARGET)
else ifdef CROSSCOMPILE
all: $(TARGET)
else
all:
	$(info compositor only builds on Linux or when cross-compiling; skipping.)
endif

# TARGET is declared phony so the copy always runs, ensuring priv/compositor
# always reflects the current target's binary even when switching between
# rpi3 (armv7) and rpi5 (aarch64) in the same worktree.
.PHONY: $(TARGET)
$(TARGET): $(LINKED_BIN)
	cp $< $@

$(LINKED_BIN): $(OBJS)
	$(CC) $(OBJS) -o $@ $(LDFLAGS)

$(OBJ_DIR)/%.o: %.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(OBJ_DIR):
	mkdir -p $@

clean:
	rm -rf .obj $(TARGET)

.PHONY: all clean
