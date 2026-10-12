# Makefile — Tracker build for desktop Linux and Termux (Android)
# Usage:  make              (desktop)
#         make PLATFORM=termux

CXX       ?= g++
SRC       = main.c buttons.c v4l2_cam.c
BIN       = tracker
SAMPLER_SRC = sampler.c
SAMPLER_BIN = sampler
GIT_VERSION := $(shell git describe --tags --abbrev=0 2>/dev/null || echo dev)

# ── Platform detection ──
PLATFORM ?= $(shell [ -d /data/data/com.termux/files/usr ] && echo termux || echo desktop)

# Bez -O by se tracker i vision glue kód přeložily na -O0. Per-frame smyčka
# (blob detekce, morfologie, perspektiva) je čistě CPU vázaná, takže -O2 je na
# Pi nejlevnější zrychlení. -march=native je bezpečné: binárka se staví přímo na
# boxu (prepare-sd.sh host binaries nekopíruje), takže cílí na A72, na kterém běží.
# Termux (Android) zůstává bez -march, ať je binárka přenositelná.
ifeq ($(PLATFORM),termux)
    PREFIX  ?= /data/data/com.termux/files/usr
    CXXFLAGS += -O2 -pipe -I$(PREFIX)/include
    LDFLAGS  += -L$(PREFIX)/lib
else
    CXXFLAGS += -O2 -pipe -march=native
    LDFLAGS  +=
endif

# ── libjpeg-turbo (dekódování MJPEG z kamery) ──
# V4L2 kamera dodává MJPEG stream; dekóduje ho libjpeg-turbo.
JPEG_CFLAGS := $(shell pkg-config --cflags libjpeg 2>/dev/null)
JPEG_LIBS   := $(shell pkg-config --libs libjpeg 2>/dev/null || echo -ljpeg)

# ── grayskull (tiny C vision) ──
# Hlavičková knihovna ve third_party/ (blobs, morfologie, perspektiva).
VISION_CFLAGS := -Ithird_party

# ── V4L2 kamera ──
# Jen na Linuxu; Termux/Android V4L2 nemá, takže main.c + v4l2_cam.c se staví
# s HAVE_V4L2=0 (stuby, kamera se neotevře, zvuk a RF tlačítka jedou dál).
ifeq ($(PLATFORM),termux)
    HAVE_V4L2 := 0
else
    HAVE_V4L2 := 1
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

# Tracker si bere i GPIOD_CFLAGS/_LIBS: od 433 MHz tlačítka F (restart
# služby) čte EV1527 na GPIO15. Bez libgpiod (HAVE_GPIOD=0) je RF vypnuté.
ALL_CXXFLAGS = $(CXXFLAGS) $(GPIOD_CFLAGS) $(VISION_CFLAGS) $(JPEG_CFLAGS) $(SDL2_CFLAGS) -DHAVE_V4L2=$(HAVE_V4L2) -DGIT_VERSION='"$(GIT_VERSION)"'
ALL_LDFLAGS  = $(LDFLAGS) $(SDL2_LIBS) $(RAYLIB_LIBS) $(JPEG_LIBS) $(GPIOD_LIBS) $(SYS_LIBS)

SAMPLER_CXXFLAGS = $(CXXFLAGS) $(SDL2_CFLAGS) $(GPIOD_CFLAGS) -DGIT_VERSION='"$(GIT_VERSION)"'
SAMPLER_LDFLAGS  = $(LDFLAGS) $(SDL2_LIBS) $(GPIOD_LIBS) -lm -lpthread

.PHONY: all clean docs samples encode-samples

all: $(BIN) $(SAMPLER_BIN)

$(BIN): $(SRC)
	$(CXX) $(SRC) -o $@ $(ALL_CXXFLAGS) $(ALL_LDFLAGS)

$(SAMPLER_BIN): $(SAMPLER_SRC)
	$(CXX) $< -o $@ $(SAMPLER_CXXFLAGS) $(SAMPLER_LDFLAGS)

docs:
	sh docs/build-docs.sh

# samples/*.opus -> samples/*.wav. V gitu je jen Opus (102 MB); WAV (141 MB)
# jsou generovane a sampler je z nich prevadi. prepare-sd.sh si tohle pusti
# taky, takze do image se rsyncne uz hotovy WAV a box nepotrebuje ffmpeg.
samples:
	./samples-decode.sh

# Opcny smer: samples/raw/*.wav (642 MB stereo, mimo git) -> samples/*.opus.
# Neni soucasti `samples`, aby prepare-sd.sh pri stavbe image nikdy neprevedl
# 642 MB originalu — staci ze zavola decode nad tim, co uz v gitu je.
encode-samples:
	./samples-encode.sh

clean:
	rm -f $(BIN) $(BIN)_test $(SAMPLER_BIN)
