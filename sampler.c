#ifndef GIT_VERSION
#define GIT_VERSION "dev"
#endif
#define VERSION_STRING GIT_VERSION

#include <SDL2/SDL.h>
#include <SDL2/SDL_mixer.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <csignal>
#include <string>
#include <vector>

#if HAVE_GPIOD
#include <gpiod.h>
#endif

#define MAX_BUTTONS 20
#define RF_GPIO_LINE 22
#define RF_CHIP "gpiochip0"

#define LCD_COLS 16
#define EV1527_BITS 24
#define LCD_BACKLIGHT 0x08

struct Slot {
    uint32_t code;
    int channel;
    std::string file;
    Mix_Chunk* chunk;
    uint64_t lastUs;
};

struct Decoder {
    int state;
    int bitCount;
    uint32_t code;
    uint64_t lastUs;
    int highUs;
    int haveHigh;
};

static char boxLetter = 'B';
static int listenMode = 0;
static int simulateMode = 0;
static int simulateRf = 0;
static std::vector<uint32_t> simCodes;
static int lcdAddr = 0x27;
static int lcdEnabled = 1;
static int teUs = 320;
static uint64_t debounceUs = 300000ull;
static uint64_t pressCount = 0;
static int numSlots = 0;
static Slot slots[MAX_BUTTONS];
static int lcdFd = -1;
static uint32_t lastListenCode = 0;
static uint64_t lastListenUs = 0;
static volatile sig_atomic_t running = 1;

static void onSignal(int) { running = 0; }

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

static void lcdNibble(uint8_t nibble, uint8_t rs) {
    uint8_t val = LCD_BACKLIGHT | (nibble << 4) | (rs ? 0x01 : 0x00);
    uint8_t out[1] = { (uint8_t)(val | 0x04) };
    if (write(lcdFd, out, 1) != 1) return;
    out[0] = val;
    if (write(lcdFd, out, 1) != 1) return;
}

static void lcdByte(uint8_t c, uint8_t rs) {
    lcdNibble(c >> 4, rs);
    lcdNibble(c & 0x0f, rs);
}

static void lcdCmd(uint8_t c) {
    lcdByte(c, 0);
    if (c == 0x01) usleep(2000);
    else usleep(120);
}

static void lcdData(uint8_t c) {
    lcdByte(c, 1);
    usleep(60);
}

static void lcdInit() {
    usleep(50000);
    int bits4[] = { 0x03, 0x03, 0x03, 0x02 };
    for (int i = 0; i < 4; i++) {
        lcdNibble(bits4[i], 0);
        usleep(i == 0 ? 4500 : 160);
    }
    lcdCmd(0x28);
    lcdCmd(0x0c);
    lcdCmd(0x06);
    lcdCmd(0x01);
}

static int lcdOpen() {
    const char* dev = "/dev/i2c-1";
    lcdFd = open(dev, O_RDWR);
    if (lcdFd < 0) {
        fprintf(stderr, "Warning: cannot open %s: %s\n", dev, strerror(errno));
        return -1;
    }
    if (ioctl(lcdFd, I2C_SLAVE, lcdAddr) < 0) {
        fprintf(stderr, "Warning: I2C address 0x%02x unavailable: %s\n",
                lcdAddr, strerror(errno));
        close(lcdFd);
        lcdFd = -1;
        return -1;
    }
    lcdInit();
    return 0;
}

static void lcdLine(int row, const std::string& text) {
    if (lcdFd < 0) return;
    lcdCmd(row == 0 ? 0x80 : 0xc0);
    int i = 0;
    for (i = 0; i < LCD_COLS; i++) {
        if (i < (int)text.size()) lcdData((uint8_t)text[i]);
        else lcdData(' ');
    }
}

static void lcdStatusReady() {
    char l1[LCD_COLS + 1];
    snprintf(l1, sizeof(l1), "BOX %c  READY", boxLetter);
    char l2[LCD_COLS + 1];
    snprintf(l2, sizeof(l2), "%d pads armed", numSlots);
    lcdLine(0, l1);
    lcdLine(1, l2);
}

static void lcdStatusHit(int idx) {
    char l1[LCD_COLS + 1];
    snprintf(l1, sizeof(l1), "BOX %c S%02d #%llu",
             boxLetter, idx + 1, (unsigned long long)pressCount);
    lcdLine(0, l1);
    std::string f = slots[idx].file;
    if (f.size() > LCD_COLS) f.resize(LCD_COLS);
    lcdLine(1, f);
}

static void lcdStatusListen(uint32_t code) {
    char l2[LCD_COLS + 1];
    snprintf(l2, sizeof(l2), "code=%u", code);
    lcdLine(0, "BOX %c LISTEN");
    lcdLine(1, l2);
}

static void loadMap(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) {
        fprintf(stderr, "Warning: cannot open map '%s'\n", path);
        return;
    }
    char line[512];
    int n = 0;
    while (fgets(line, sizeof(line), f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;

        char* end = NULL;
        unsigned long code = strtoul(p, &end, 10);
        p = end;
        while (*p == ' ' || *p == '\t' || *p == ',') p++;

        int k = 0;
        char name[256];
        while (*p && *p != '\n' && *p != '\r') {
            if (*p == ' ' || *p == '\t') {
                while (*p == ' ' || *p == '\t') p++;
                if (*p && *p != '\n' && *p != '\r') name[k++] = ' ';
                continue;
            }
            name[k++] = *p++;
        }
        name[k] = '\0';
        while (k > 0 && (name[k - 1] == ' ')) name[--k] = '\0';
        if (k == 0) continue;

        if (n >= MAX_BUTTONS) {
            fprintf(stderr,
                    "Warning: map '%s' has more than %d entries; ignoring %lu\n",
                    path, MAX_BUTTONS, code);
            continue;
        }
        slots[n].code = (uint32_t)code;
        slots[n].channel = n;
        slots[n].file = name;
        slots[n].chunk = NULL;
        slots[n].lastUs = 0;
        n++;
    }
    fclose(f);
    numSlots = n;
    fprintf(stdout, "map: %d slot(s) from %s\n", numSlots, path);
}

static int classifyShort(int us) {
    return us >= 6 * teUs / 10 && us <= 16 * teUs / 10;
}

static int classifyBit(int us) {
    if (us >= 6 * teUs / 10 && us <= 16 * teUs / 10) return 0;
    if (us >= 20 * teUs / 10 && us <= 40 * teUs / 10) return 1;
    return -1;
}

static void onCode(uint32_t code) {
    pressCount++;
    if (listenMode) {
        uint64_t t = nowUs();
        if (code == lastListenCode && lastListenUs &&
            t - lastListenUs < debounceUs)
            return;
        lastListenCode = code;
        lastListenUs = t;
        fprintf(stdout, "code=%u, id=%u, key=%u\n",
                code, code >> 4, code & 0x0f);
        fflush(stdout);
        if (lcdEnabled) {
            char l2[LCD_COLS + 1];
            snprintf(l2, sizeof(l2), "code=%u", code);
            lcdLine(0, "BOX %c LISTEN");
            lcdLine(1, l2);
        }
        return;
    }
    for (int i = 0; i < numSlots; i++) {
        if (slots[i].code == code) {
            uint64_t t = nowUs();
            if (slots[i].lastUs && t - slots[i].lastUs < debounceUs) return;
            if (!slots[i].chunk) return;
            slots[i].lastUs = t;
            Mix_HaltChannel(slots[i].channel);
            Mix_PlayChannel(slots[i].channel, slots[i].chunk, 0);
            if (lcdEnabled) lcdStatusHit(i);
            return;
        }
    }
    fprintf(stderr, "code=%u not in map\n", code);
}

static void decoderPush(Decoder& d, uint64_t evUs, int rising) {
    if (d.lastUs && evUs > d.lastUs) {
        int durn = (int)(evUs - d.lastUs);
        if (rising) {
            if (durn >= 15 * teUs) {
                if (d.haveHigh && classifyShort(d.highUs)) {
                    d.state = 1;
                    d.bitCount = 0;
                    d.code = 0;
                } else {
                    d.state = 0;
                }
                d.haveHigh = 0;
            } else if (durn >= 4 * teUs) {
                d.state = 0;
                d.bitCount = 0;
                d.haveHigh = 0;
            } else if (d.state == 1) {
                if (d.haveHigh) {
                    int b = classifyBit(d.highUs);
                    if (b >= 0) {
                        d.code = (d.code << 1) | (uint32_t)b;
                        d.bitCount++;
                        d.haveHigh = 0;
                        if (d.bitCount == EV1527_BITS) {
                            onCode(d.code);
                            d.state = 0;
                            d.bitCount = 0;
                        }
                    } else {
                        d.state = 0;
                        d.bitCount = 0;
                        d.haveHigh = 0;
                    }
                }
            }
        } else {
            d.highUs = durn;
            d.haveHigh = 1;
        }
    }
    d.lastUs = evUs;
}

static void simulateRfFrame(uint32_t code) {
    Decoder dec;
    std::memset(&dec, 0, sizeof(dec));
    uint64_t t = nowUs() + 1000;
    decoderPush(dec, t, 1);
    for (int rep = 0; rep < 4; rep++) {
        t += (uint64_t)teUs;
        decoderPush(dec, t, 0);
        t += 31ull * (uint64_t)teUs;
        decoderPush(dec, t, 1);
        for (int i = EV1527_BITS - 1; i >= 0; i--) {
            int bit = (code >> i) & 1;
            t += (uint64_t)(bit ? 3 : 1) * teUs;
            decoderPush(dec, t, 0);
            t += (uint64_t)(bit ? 1 : 3) * teUs;
            decoderPush(dec, t, 1);
        }
    }
}

#if HAVE_GPIOD
static struct gpiod_chip* rfChip = NULL;
static struct gpiod_line* rfLine = NULL;

static int rfInit() {
    rfChip = gpiod_chip_open_by_name(RF_CHIP);
    if (!rfChip) return -1;
    rfLine = gpiod_chip_get_line(rfChip, RF_GPIO_LINE);
    if (!rfLine) {
        gpiod_chip_close(rfChip);
        rfChip = NULL;
        return -1;
    }
    if (gpiod_line_request_both_edges_events(rfLine, "sampler") < 0) {
        gpiod_chip_close(rfChip);
        rfChip = NULL;
        rfLine = NULL;
        return -1;
    }
    return 0;
}

static int rfDrain(uint64_t* tOut, int* rOut, int maxN) {
    int n = 0;
    while (n < maxN) {
        struct timespec timeout = { 0, 0 };
        int ret = gpiod_line_event_wait(rfLine, &timeout);
        if (ret <= 0) break;
        struct gpiod_line_event ev;
        if (gpiod_line_event_read(rfLine, &ev) < 0) break;
        tOut[n] = (uint64_t)ev.ts.tv_sec * 1000000ull +
                  (uint64_t)ev.ts.tv_nsec / 1000ull;
        rOut[n] = (ev.event_type == GPIOD_LINE_EVENT_RISING_EDGE);
        n++;
    }
    return n;
}
#else
static int rfInit() { return -1; }

static int rfDrain(uint64_t*, int*, int) { return 0; }
#endif

static void usage(const char* prog) {
    fprintf(stderr,
        "Usage: %s --box b|c [options]\n"
        "\n"
        "  433 MHz EV1527 button sampler for tracker boxes B/C\n"
        "\n"
        "Options:\n"
        "  --box b|c           box identity (required; shown on LCD)\n"
        "  --map FILE          code->sample map (default: mapa.csv)\n"
        "  --samples-dir DIR   sample directory (default: samples)\n"
        "  --lcd-addr HEX      PCF8574 I2C address, or off (default: 0x27)\n"
        "  --te-us N           EV1527 base timing in microseconds (default: 320)\n"
        "  --debounce-ms N     per-button debounce window (default: 300)\n"
        "  --listen            decode-only: print received codes (build mapa.csv)\n"
        "  --simulate          read codes from stdin instead of the RF receiver\n"
        "  --simulate-rf C...  self-test: synthesize EV1527 frames for the given codes\n"
        "  --version, -v       print version and exit\n",
        prog);
}

int main(int argc, char* argv[]) {
    const char* map = "mapa.csv";
    const char* samplesDir = "samples";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-v") == 0) {
            std::printf("sampler %s\n", VERSION_STRING);
            return 0;
        }
    }

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--box") == 0 && i + 1 < argc) {
            char b = argv[++i][0];
            if (b == 'b' || b == 'B') boxLetter = 'B';
            else if (b == 'c' || b == 'C') boxLetter = 'C';
            else { fprintf(stderr, "Error: --box expects b or c\n"); return -1; }
        } else if (strcmp(argv[i], "--map") == 0 && i + 1 < argc) {
            map = argv[++i];
        } else if (strcmp(argv[i], "--samples-dir") == 0 && i + 1 < argc) {
            samplesDir = argv[++i];
        } else if (strcmp(argv[i], "--lcd-addr") == 0 && i + 1 < argc) {
            const char* a = argv[++i];
            if (strcmp(a, "off") == 0 || strcmp(a, "none") == 0) lcdEnabled = 0;
            else lcdAddr = (int)strtoul(a, NULL, 0);
        } else if (strcmp(argv[i], "--te-us") == 0 && i + 1 < argc) {
            teUs = std::atoi(argv[++i]);
            if (teUs <= 0) { fprintf(stderr, "Error: --te-us must be positive\n"); return -1; }
        } else if (strcmp(argv[i], "--debounce-ms") == 0 && i + 1 < argc) {
            int ms = std::atoi(argv[++i]);
            if (ms < 0) { fprintf(stderr, "Error: --debounce-ms must be >= 0\n"); return -1; }
            debounceUs = (uint64_t)ms * 1000ull;
        } else if (strcmp(argv[i], "--listen") == 0) {
            listenMode = 1;
        } else if (strcmp(argv[i], "--simulate") == 0) {
            simulateMode = 1;
        } else if (strcmp(argv[i], "--simulate-rf") == 0) {
            simulateRf = 1;
            while (i + 1 < argc && argv[i + 1][0] != '-') {
                simCodes.push_back((uint32_t)strtoul(argv[++i], NULL, 0));
            }
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        }
    }

    if (boxLetter != 'B' && boxLetter != 'C') {
        usage(argv[0]);
        return -1;
    }

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);
    signal(SIGHUP, onSignal);

    if (!listenMode) {
        if (SDL_Init(SDL_INIT_AUDIO) < 0) {
            fprintf(stderr, "Error: SDL audio init failed: %s\n", SDL_GetError());
            return -1;
        }
        if (Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 1024) < 0) {
            fprintf(stderr, "Error: Mix_OpenAudio failed: %s\n", Mix_GetError());
            return -1;
        }
        Mix_AllocateChannels(MAX_BUTTONS);
    }

    if (!listenMode)
        loadMap(map);
    if (!listenMode) {
        int loaded = 0;
        for (int i = 0; i < numSlots; i++) {
            std::string path = std::string(samplesDir) + "/" + slots[i].file;
            slots[i].chunk = Mix_LoadWAV(path.c_str());
            if (slots[i].chunk) loaded++;
            else fprintf(stderr, "Warning: cannot load sample '%s'\n", path.c_str());
        }
        fprintf(stdout, "sample: %d/%d loaded from %s/\n", loaded, numSlots, samplesDir);
    }

    if (lcdEnabled) {
        if (lcdOpen() == 0) {
            if (listenMode) lcdLine(0, "BOX %c LISTEN");
            else lcdStatusReady();
        } else {
            lcdEnabled = 0;
        }
    }

    fprintf(stdout,
            "sampler %s (box %c, %s, te=%dus, debounce=%llums)\n",
            VERSION_STRING, boxLetter,
            listenMode ? "listen" : "play",
            teUs, (unsigned long long)(debounceUs / 1000ull));
    fflush(stdout);

    int haveRf = 0;
    if (!simulateMode && !simulateRf) {
        haveRf = (rfInit() == 0);
        if (!haveRf) {
#if HAVE_GPIOD
            fprintf(stderr,
                    "Error: cannot open %s line %d: %s\n",
                    RF_CHIP, RF_GPIO_LINE, strerror(errno));
#else
            fprintf(stderr,
                    "Error: built without libgpiod; RF unavailable.\n"
                    "Install libgpiod-dev and rebuild for RF, or use --simulate.\n");
#endif
            return -1;
        }
    }

    Decoder dec;
    std::memset(&dec, 0, sizeof(dec));

    if (simulateRf) {
        if (simCodes.empty()) {
            fprintf(stderr, "Error: --simulate-rf needs at least one code\n");
            return -1;
        }
        for (size_t i = 0; i < simCodes.size(); i++) simulateRfFrame(simCodes[i]);
    } else if (simulateMode) {
        char line[512];
        while (running && fgets(line, sizeof(line), stdin)) {
            char* p = line;
            while (*p == ' ' || *p == '\t') p++;
            if (*p == '#' || *p == '\n' || *p == '\0') continue;
            onCode((uint32_t)strtoul(p, NULL, 10));
        }
    } else {
        while (running) {
            uint64_t t[32];
            int r[32];
            int n = rfDrain(t, r, 32);
            if (n == 0) {
                usleep(2000);
                continue;
            }
            for (int i = 0; i < n; i++) decoderPush(dec, t[i], r[i]);
        }
    }

#if HAVE_GPIOD
    if (rfLine) gpiod_line_release(rfLine);
    if (rfChip) gpiod_chip_close(rfChip);
#endif
    if (lcdFd >= 0) close(lcdFd);
    if (!listenMode) {
        for (int i = 0; i < numSlots; i++)
            if (slots[i].chunk) Mix_FreeChunk(slots[i].chunk);
        Mix_CloseAudio();
        SDL_Quit();
    }
    return 0;
}