CC ?= gcc
CFLAGS += -Wall -Wextra -Wno-unused-parameter -O2 -std=gnu99
CFLAGS += $(shell pkg-config --cflags cairo libdrm fontconfig libjpeg libpng 2>/dev/null)
LDFLAGS += $(shell pkg-config --libs cairo libdrm fontconfig libjpeg libpng 2>/dev/null) -lm

SRCS = compositor.c protocol.c image.c display.c display_fbdev.c display_drm.c render.c overlay.c
OBJS = $(SRCS:.c=.o)
TARGET = ../../priv/compositor

ifeq ($(shell uname -s),Linux)
all: $(TARGET)
else ifdef CROSSCOMPILE
all: $(TARGET)
else
all:
	$(info compositor only builds on Linux or when cross-compiling; skipping.)
endif

$(TARGET): $(OBJS)
	$(CC) $(OBJS) -o $@ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f $(OBJS) $(TARGET)

.PHONY: all clean
