# Makefile — Tracker build for desktop Linux and Termux (Android)
# Usage:  make              (desktop)
#         make PLATFORM=termux

CXX      ?= g++
SRC       = main.c
BIN       = tracker

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

# ── Raylib ──
RAYLIB_LIBS := $(shell pkg-config --libs raylib 2>/dev/null || echo "-lraylib")

# ── System libs ──
SYS_LIBS := -lGL -lm -lpthread -ldl
ifeq ($(PLATFORM),desktop)
    SYS_LIBS += -lrt -lX11
endif

ALL_CXXFLAGS = $(CXXFLAGS) $(OPENCV_CFLAGS) $(SDL2_CFLAGS)
ALL_LDFLAGS  = $(LDFLAGS) $(SDL2_LIBS) $(RAYLIB_LIBS) $(OPENCV_LIBS) $(SYS_LIBS)

.PHONY: all clean

all: $(BIN)

$(BIN): $(SRC)
	$(CXX) $< -o $@ $(ALL_CXXFLAGS) $(ALL_LDFLAGS)

clean:
	rm -f $(BIN) $(BIN)_test
