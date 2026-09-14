# Makefile — Tracker build for desktop Linux and Termux (Android)
# Usage:  make              (desktop)
#         make PLATFORM=termux

CXX       ?= g++
SRC       = main.c
BIN       = tracker
SAMPLER_SRC = sampler.c
SAMPLER_BIN = sampler
GIT_VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null || echo dev)

# ── Platform detection ──
PLATFORM ?= $(shell uname -m | sed 's/x86_64/desktop/;s/aarch64/termux/')

ifeq ($(PLATFORM),termux)
    PREFIX  ?= /data/data/com.termux/files/usr
    CXXFLAGS += -I$(PREFIX)/include
    LDFLAGS  += -L$(PREFIX)/lib
else
    CXXFLAGS +=
    LDFLAGS  +=
endif

# ── OpenCV (auto-detect pkg-config name) ──
ifeq ($(PLATFORM),termux)
    ifneq ($(shell pkg-config --exists opencv4 2>/dev/null && echo yes),)
        OPENCV_CFLAGS := $(shell pkg-config --cflags opencv4)
        OPENCV_LIBS   := $(shell pkg-config --libs opencv4)
    else ifneq ($(shell pkg-config --exists opencv 2>/dev/null && echo yes),)
        OPENCV_CFLAGS := $(shell pkg-config --cflags opencv)
        OPENCV_LIBS   := $(shell pkg-config --libs opencv)
    else
        # OpenCV 4.x (Termux ships 4.14)
        OPENCV_CFLAGS := -I$(PREFIX)/include/opencv4
        OPENCV_LIBS   := -lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib3d -lopencv_geometry -lopencv_tracking
    endif
else
    # Desktop: avoid full opencv5 pkg-config (pulls VTK viz module)
    OPENCV_CFLAGS := -I/usr/include/opencv5
    ifneq ($(wildcard /usr/lib/libopencv_calib.so),)
        # OpenCV 5.x
        OPENCV_LIBS := -lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib -lopencv_geometry -lopencv_tracking
    else
        # OpenCV 4.x
        OPENCV_LIBS := -lopencv_core -lopencv_videoio -lopencv_video -lopencv_imgproc -lopencv_calib3d -lopencv_geometry -lopencv_tracking
    endif
endif

# ── SDL2 ──
SDL2_CFLAGS := $(shell pkg-config --cflags sdl2 2>/dev/null)
SDL2_LIBS   := $(shell pkg-config --libs sdl2 SDL2_mixer 2>/dev/null || echo "-lSDL2 -lSDL2_mixer")

# ── libgpiod (sampler RF receiver; optional on desktop) ──
ifeq ($(shell pkg-config --exists libgpiod && echo yes),yes)
    GPIOD_CFLAGS := $(shell pkg-config --cflags libgpiod) -DHAVE_GPIOD=1
    GPIOD_LIBS   := $(shell pkg-config --libs libgpiod)
else
    GPIOD_CFLAGS := -DHAVE_GPIOD=0
    GPIOD_LIBS   :=
endif

# ── Raylib ──
RAYLIB_LIBS := $(shell pkg-config --libs raylib 2>/dev/null || echo "-lraylib")

# ── System libs ──
SYS_LIBS := -lGL -lm -lpthread -ldl
ifeq ($(PLATFORM),desktop)
    SYS_LIBS += -lrt -lX11
endif

ALL_CXXFLAGS = $(CXXFLAGS) $(OPENCV_CFLAGS) $(SDL2_CFLAGS) -DGIT_VERSION='"$(GIT_VERSION)"'
ALL_LDFLAGS  = $(LDFLAGS) $(SDL2_LIBS) $(RAYLIB_LIBS) $(OPENCV_LIBS) $(SYS_LIBS)

SAMPLER_CXXFLAGS = $(CXXFLAGS) $(SDL2_CFLAGS) $(GPIOD_CFLAGS) -DGIT_VERSION='"$(GIT_VERSION)"'
SAMPLER_LDFLAGS  = $(LDFLAGS) $(SDL2_LIBS) $(GPIOD_LIBS) -lm -lpthread

.PHONY: all clean docs

all: $(BIN) $(SAMPLER_BIN)

$(BIN): $(SRC)
	$(CXX) $< -o $@ $(ALL_CXXFLAGS) $(ALL_LDFLAGS)

$(SAMPLER_BIN): $(SAMPLER_SRC)
	$(CXX) $< -o $@ $(SAMPLER_CXXFLAGS) $(SAMPLER_LDFLAGS)

docs:
	sh docs/build-docs.sh

clean:
	rm -f $(BIN) $(BIN)_test $(SAMPLER_BIN)
