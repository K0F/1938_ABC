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
#include <poll.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <ctime>
#include <csignal>
#include <unistd.h>
#include <sys/wait.h>
#include <string>
#include <vector>

#if HAVE_GPIOD
#include <gpiod.h>
#endif

#define MAX_BUTTONS 20
// Výchozí pin přijímače je BCM 15 (fyzický pin 33) — tam je DATA
// opravdu zapojený. Předpis to uvádí jako „GPIO15 (GPIO22)", kde 15 je
// fyzický pin hlavičky a 22 BCM číslo; na zapojeném boxu ale DATA sedí
// v pinu 33, ne 15. Přepínač --rf-pin to nechá přepsat.
#define RF_GPIO_LINE 15
#define RF_CHIP "gpiochip0"

#define LCD_COLS 16
#define EV1527_BITS 24
#define LCD_BACKLIGHT 0x08

// Mixer běží na 24 kHz, ne na 44.1 kHz. SDL_mixer převádí každý vzorek na
// formát mixeru hned po načtení, takže rychlost mixeru — ne rychlost
// souboru — určuje, kolik RAM vrstva zabere: 96 kB/s mono 24 kHz proti
// 176 kB/s stereo 44.1 kHz. Pěti současně znějícím vrstvám to dělá 240 MB
// místo 480 MB, což je na boxu s 1 GB rozdíl mezi fungováním a OOM.
// Box má mono výstup a 12 kHz audio pásmo v 24 kHz mu stačí; samples-decode.sh
// z Opus dělá WAV přesně v tomhle formátu (24 kHz je navíc rate, kterou umí
// libopus — 22050 neumí).
#define MIX_RATE 24000

struct Slot {
    uint32_t code;
    int channel;
    std::string file;
    Mix_Chunk* chunk;
    uint64_t lastUs;
    // Slot s restartUnits != "" je akční: místo přehrání samplu spustí
    // `systemctl restart` na uvedených jednotkách. Zbytek je audio.
    std::string restartUnits;
    // Od kdy se vrstva rozfádívá (0 = nehraje). Mix_Volume je na kanál,
    // takže každá vrstva má vlastní, nezávislý fade.
    uint64_t fadeStartUs;
    // 1 = Mix_LoadWAV už proběhl (až to selhalo, ať se to při každém
    // stisku nezkoušelo znovu a neplavalo se to do journalu).
    int loadTried;
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
static int learnMode = 0;
static int simulateMode = 0;
static int simulateRf = 0;
static int audioOk = 0;
// --dry-run: akční sloty se vypíší, ale systemctl se nespustí. Bez toho
// by nebylo jak vůbec ověřit, že mapa parsuje správně, aniž se něco
// restartovalo.
static int dryRun = 0;
static int noAudio = 0;
// Doba rozfádění vrstvy po stisku. Vrstva se prehraje v loopu, takže pak
// zní, dokud ji někdo nevypne; stisk rozfádí od ticha, aby se pěkně
// vkradla do současně znějících vrstev.
static uint64_t fadeUs = 2000000ull;
// Líné načítání: vzorek se čte až při prvním stisku. Vrstev je v mapě
// typicky víc, než se kdy hraje najednou, a načíst jich všechny znamená
// držet v RAM stovky MB. --eager to vrací na startu všechny.
static int eagerLoad = 0;
static const char* mapPath = "map.csv";
static const char* samplesDir = "samples";
static int learnQuit = 0;
static std::vector<uint32_t> simCodes;
static int lcdAddr = 0x27;
static int lcdEnabled = 1;
static int teUs = 320;
// Tyto tlačítka nevysílají jeden rámec, ale opakovaně po dobu přes
// sekundu. Při 300 ms propadla každá retransmise do debounce a stisk
// spustil 2s vzorek 5x za sebou (slyšitelné trhání). 2000 ms přesahuje
// celý burst, takže jeden stisk = jeden mix. Měřeno na boxu A 2026-09-29.
static uint64_t debounceUs = 2000000ull;
static unsigned rfPinOverride = RF_GPIO_LINE;
static uint64_t pressCount = 0;
static int numSlots = 0;
static Slot slots[MAX_BUTTONS];
static int lcdFd = -1;
static uint32_t lastListenCode = 0;
static uint64_t lastListenUs = 0;
// Potvrzení kódu: šum občas vyplodí rámec, který projde jako platný
// 24bitový kód (a má unique id, takže ho debounce nepotlačí). Skutečné
// tlačítko vysílá opakovaně, takže požadujeme, aby se kód potvrdil
// CONFIRM_MIN× za sebou v rámci CONFIRM_WINDOW_US, než ho vypíšeme.
static int confirmMin = 1;
static uint64_t confirmWindowUs = 120000ull;  // 120 ms
static uint32_t candCode = 0;
static int candCount = 0;
static uint64_t candUs = 0;
// Akční sloty (@restart) jsou záměrně vypnuté, dokud se to výslovně
// nepovolí: mapa se načítá i v --listen, kde by stisk tlačítka jinak
// restartoval služby jen tím, že někdo poslouchal. sampler.service to
// musí zapnout explicitně.
static int restartAllowed = 0;
static uint32_t lastLearnCode = 0;
static uint64_t lastLearnUs = 0;
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
        // Akční slot: "@restart unit1 unit2". Na rozdíl od audia nemá
        // smysl cpát z cesty samples/ — jde o jednotky systemd.
        slots[n].restartUnits.clear();
        if (k >= 8 && strncmp(name, "@restart", 8) == 0) {
            if (!restartAllowed) {
                fprintf(stderr,
                        "Warning: map '%s' wants @restart, but "
                        "--allow-restart was not given; code %lu is ignored\n",
                        path, code);
                continue;
            }
            // "unit1 unit2" nebo "unit1,unit2" — obojí smí být.
            std::string units = std::string(name + 8);
            for (size_t i = 0; i < units.size(); i++)
                if (units[i] == ',') units[i] = ' ';
            slots[n].restartUnits = units;
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

// --- learn režim -------------------------------------------------------
// Interaktivní registrace tlačítek: po stisku se zeptá na název samplu a
// rovnou ho zapíše do mapy. Zápis jde na disk hned po každém tlačítku —
// když se v polovině registrace odpojí napájení, zůstane v mapě vše, co už
// bylo stisknuto, a zbytek stačí doplnit.
static int learnDefaultName(int idx, char* out, size_t n) {
    snprintf(out, n, "sample_%c_%02d.wav", (char)(boxLetter | 0x20), idx);
    return 0;
}

static int learnReadLine(char* out, size_t n) {
    if (!fgets(out, (int)n, stdin)) return -1;
    size_t k = strlen(out);
    while (k > 0 && (out[k - 1] == '\n' || out[k - 1] == '\r')) out[--k] = '\0';
    return 0;
}

static int learnAppendMap(uint32_t code, const char* name) {
    FILE* f = fopen(mapPath, "a");
    if (!f) {
        fprintf(stderr, "Error: cannot append to map '%s': %s\n",
                mapPath, strerror(errno));
        return -1;
    }
    fprintf(f, "%u, %s\n", code, name);
    fclose(f);
    return 0;
}

static void learnCode(uint32_t code) {
    uint64_t t = nowUs();
    if (code == lastLearnCode && lastLearnUs && t - lastLearnUs < debounceUs)
        return;
    lastLearnCode = code;
    lastLearnUs = t;
    pressCount++;

    for (int i = 0; i < numSlots; i++) {
        if (slots[i].code == code) {
            fprintf(stdout, "code=%u (id=%u, key=%u) -> S%02d %s  [uz znameno]\n",
                    code, code >> 4, code & 0x0f, i + 1, slots[i].file.c_str());
            fflush(stdout);
            return;
        }
    }
    if (numSlots >= MAX_BUTTONS) {
        fprintf(stderr, "code=%u — mapa je plna (%d tlačítek)\n", code, MAX_BUTTONS);
        return;
    }

    char def[64];
    learnDefaultName(numSlots + 1, def, sizeof(def));
    fprintf(stdout, "code=%u (id=%u, key=%u) -> S%02d [%s]: ",
            code, code >> 4, code & 0x0f, numSlots + 1, def);
    fflush(stdout);

    char line[256];
    if (learnReadLine(line, sizeof(line)) < 0) {
        running = 0;
        return;
    }
    if (strcmp(line, "q") == 0 || strcmp(line, "Q") == 0) {
        learnQuit = 1;
        running = 0;
        return;
    }
    const char* name = line[0] ? line : def;

    if (learnAppendMap(code, name) < 0) return;
    slots[numSlots].code = code;
    slots[numSlots].file = name;
    slots[numSlots].lastUs = 0;
    slots[numSlots].restartUnits.clear();
    numSlots++;
    fprintf(stdout, "  zapsáno do %s (%d/%d)\n", mapPath, numSlots, MAX_BUTTONS);
    fflush(stdout);
    if (lcdEnabled) {
        char l2[LCD_COLS + 1];
        snprintf(l2, sizeof(l2), "S%02d ok", numSlots);
        lcdLine(0, "BOX %c LEARN");
        lcdLine(1, l2);
    }
}

// Akční slot: `systemctl restart` na jednotkách z mapy. system() je tu
// záměrně — je to jediný způsob jak volat systemctl z C a vstup pochází
// z mapy, kterou vlastní správce boxu (viz --no-restart a security
// note v README: mapa musí být pod kontrolou stejně jako služby).
// argv se předává bez shellu, aby se jméno jednotky nedalo zmršit.
static void doRestart(const std::string& units, int slotIdx) {
    // "@restart tracker.service" — za slovem je mezera, která by se jinak
    // převedla na prázdný člen a vypisala se jako " @restart".
    std::string rest = units;
    while (!rest.empty() && rest[0] == ' ') rest.erase(rest.begin());
    std::vector<std::string> list;
    std::string cur;
    for (size_t i = 0; i <= rest.size(); i++) {
        if (i == rest.size() || rest[i] == ' ') {
            if (!cur.empty()) { list.push_back(cur); cur.clear(); }
        } else {
            cur += rest[i];
        }
    }
    if (list.empty()) {
        fprintf(stderr, "Warning: @restart slot S%02d has no units\n",
                slotIdx + 1);
        return;
    }
    for (size_t i = 0; i < list.size(); i++) {
        fprintf(stdout, "code=%u -> @restart %s\n", slots[slotIdx].code,
                list[i].c_str());
        fflush(stdout);
        if (dryRun) {
            fprintf(stdout, "@restart %s: dry-run, not run\n",
                    list[i].c_str());
            fflush(stdout);
            continue;
        }
        if (geteuid() != 0) {
            fprintf(stdout, "@restart %s: needs root, skipped\n",
                    list[i].c_str());
            fflush(stdout);
            continue;
        }
        pid_t pid = fork();
        if (pid == 0) {
            // Dědíme stdout, ať jde výsledek do journalu služby.
            execlp("systemctl", "systemctl", "restart", "--",
                   list[i].c_str(), (char*)NULL);
            _exit(127);
        } else if (pid > 0) {
            int status = 0;
            waitpid(pid, &status, 0);
            if (WIFEXITED(status) && WEXITSTATUS(status) == 127) {
                fprintf(stdout, "@restart %s: systemctl not found\n",
                        list[i].c_str());
            } else if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
                fprintf(stdout, "@restart %s: rc=%d\n", list[i].c_str(),
                        WEXITSTATUS(status));
            }
            fflush(stdout);
        } else {
            perror("fork");
        }
    }
}

// Načte vzorek slotu do paměti. Vrací true, když je slot přehrávatelný.
// Slot, který už jednou selhal (chybějící soubor, poškozený WAV), se znovu
// nezkouší — jinak by každý stisk vypisoval do journalu totéž.
static bool loadSample(int i) {
    if (slots[i].chunk) return true;
    if (slots[i].loadTried) return false;
    slots[i].loadTried = 1;
    std::string path = std::string(samplesDir) + "/" + slots[i].file;
    slots[i].chunk = Mix_LoadWAV(path.c_str());
    if (!slots[i].chunk)
        fprintf(stderr, "Warning: cannot load sample '%s'\n", path.c_str());
    return slots[i].chunk != NULL;
}

// Rozjede vrstvu daného slotu a začne ji rozfádívat. Mix_PlayChannel s
// loops = -1 hraje v okruhu, takže vrstva zní, dokud ji někdo nevypne —
// stisk dalšího tlačítka ji neodpojí, jen přidá další.
static void startLayer(int i) {
    Mix_HaltChannel(slots[i].channel);
    // 0 = potichu, pak to odtud odtiká fadesTick().
    Mix_Volume(slots[i].channel, fadeUs ? 0 : MIX_MAX_VOLUME);
    Mix_PlayChannel(slots[i].channel, slots[i].chunk, -1);
    slots[i].fadeStartUs = nowUs();
}

// Krátká lineární rampa na každém kanálu, který se právě rozfádívá.
// Mix_Volume je per-kanál, takže vrstvy jedou nezávisle a i během fade
// se jich může skládat víc. Volá se z hlavní smyčky (~2 ms), takže 2s
// fade má ~1000 kroků — na sluchátku to nezahrká.
static void fadesTick(void) {
    if (!audioOk) return;
    uint64_t t = nowUs();
    for (int i = 0; i < numSlots; i++) {
        if (!slots[i].fadeStartUs) continue;              // tato vrstva zrovna nehraje
        if (!Mix_Playing(slots[i].channel)) {              // došla? (loops=-1, jen pro jistotu)
            slots[i].fadeStartUs = 0;
            continue;
        }
        uint64_t el = t - slots[i].fadeStartUs;
        if (el >= fadeUs) {
            Mix_Volume(slots[i].channel, MIX_MAX_VOLUME);  // dorazeno na konec
            slots[i].fadeStartUs = 0;
            continue;
        }
        // fadeUs může být 0 (okamžitý náběh) — to už ošetřil startLayer.
        int v = (int)((uint64_t)MIX_MAX_VOLUME * el / fadeUs);
        Mix_Volume(slots[i].channel, v);
    }
}

static void onCode(uint32_t code) {
    if (learnMode) {
        learnCode(code);
        return;
    }
    if (listenMode) {
        uint64_t t = nowUs();
        // Nejdřív potvrzení: kód musí vyplnit celý rámec opakovaně.
        if (code == candCode && candCount && t - candUs <= confirmWindowUs) {
            candCount++;
        } else {
            candCode = code;
            candCount = 1;
        }
        candUs = t;
        if (candCount < confirmMin) return;
        // Po potvrzení kód nesmí potvrzovat dál — další rámce téhož stisku
        // spadají do debounce, jinak by jeden stisk vypisoval done.
        candCount = 0;
        if (code == lastListenCode && lastListenUs &&
            t - lastListenUs < debounceUs)
            return;
        lastListenCode = code;
        lastListenUs = t;
        pressCount++;
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
            // Čas se zapíše i bez samplu: bez debounce by jediný stisk
            // vypisoval do journalu desítky řádků.
            slots[i].lastUs = t;
            pressCount++;
            // Akční slot (@restart) nejprve, bez zvuku — přehrát sampl by
            // tady nedával smysl a restart chvíli trvá.
            if (!slots[i].restartUnits.empty()) {
                fprintf(stdout, "code=%u -> @restart (%s, #%llu)\n",
                        code, slots[i].restartUnits.c_str(),
                        (unsigned long long)pressCount);
                fflush(stdout);
                doRestart(slots[i].restartUnits, i);
                if (lcdEnabled) lcdStatusHit(i);
                return;
            }
            // Každý stisk jde do journalu, i když nehraje — na bezhlavém boxu
            // je to jediné, podle čeho se pozná, že 433 MHz tlačítko funguje.
            // Bez --eager se vzorek načítá tady, až když je opravdu potřeba.
            if (!loadSample(i)) {
                fprintf(stdout, "code=%u -> %s (S%02d, #%llu) VZOREK NENACHRANY\n",
                        code, slots[i].file.c_str(), i + 1,
                        (unsigned long long)pressCount);
                fflush(stdout);
                return;
            }
            if (!audioOk) {
                // --no-audio: slot je platný, jen se nepřehrává.
                fprintf(stdout, "code=%u -> %s (S%02d, #%llu) [no-audio]\n",
                        code, slots[i].file.c_str(), i + 1,
                        (unsigned long long)pressCount);
                fflush(stdout);
                return;
            }
            startLayer(i);
            fprintf(stdout, "code=%u -> %s (S%02d, #%llu) fade %llums, loop\n", code,
                    slots[i].file.c_str(), i + 1,
                    (unsigned long long)pressCount,
                    (unsigned long long)(fadeUs / 1000ull));
            fflush(stdout);
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
    rfLine = gpiod_chip_get_line(rfChip, rfPinOverride);
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
        "  --map FILE          code->sample map (default: map.csv)\n"
        "  --samples-dir DIR   sample directory (default: samples)\n"
        "  --lcd-addr HEX      PCF8574 I2C address, or off (default: 0x27)\n"
        "  --te-us N           EV1527 base timing in microseconds (default: 320)\n"
        "  --debounce-ms N     per-button debounce window (default: 2000; these\n"
        "                      buttons retransmit for over a second, so a shorter\n"
        "                      window retriggers the sample several times per press)\n"
        "  --confirm N         in --listen, require the code N times in a row\n"
        "                      to print it (default: 1 = off; 3 filters noise)\n"
        "  --allow-restart     honour @restart slots in the map (needs root;\n"
        "                      off by default so --listen can't restart units)\n"
        "  --dry-run           with --allow-restart, print what would be run\n"
        "  --fade-ms N         fade-in time of a triggered layer (default: 2000).\n"
        "                      0 fades in instantly; layers loop until stopped\n"
        "  --eager            load every sample at start instead of on first\n"
        "                      press (costs RAM: all layers resident at once)\n"
        "  --no-audio          skip audio init; decode and act, but play nothing\n"
        "                      (for testing @restart on a box with no sound card)\n"
        "  --rf-pin N          BCM GPIO line of receiver DATA (default: 15)\n"
        "  --listen            decode-only: print received codes (build map.csv)\n"
        "  --learn             register buttons interactively, writes map on disk\n"
        "  --simulate          read codes from stdin instead of the RF receiver\n"
        "  --simulate-rf C...  self-test: synthesize EV1527 frames for the given codes\n"
        "  --version, -v       print version and exit\n",
        prog);
}

int main(int argc, char* argv[]) {
    const char* map = mapPath;
    const char* samples = samplesDir;
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
            map = mapPath = argv[++i];
        } else if (strcmp(argv[i], "--samples-dir") == 0 && i + 1 < argc) {
            samples = samplesDir = argv[++i];
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
        } else if (strcmp(argv[i], "--confirm") == 0 && i + 1 < argc) {
            int n = std::atoi(argv[++i]);
            if (n < 1) { fprintf(stderr, "Error: --confirm must be >= 1\n"); return -1; }
            confirmMin = n;
        } else if (strcmp(argv[i], "--allow-restart") == 0) {
            restartAllowed = 1;
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            dryRun = 1;
        } else if (strcmp(argv[i], "--fade-ms") == 0 && i + 1 < argc) {
            int ms = std::atoi(argv[++i]);
            if (ms < 0) { fprintf(stderr, "Error: --fade-ms must be >= 0\n"); return -1; }
            fadeUs = (uint64_t)ms * 1000ull;
        } else if (strcmp(argv[i], "--eager") == 0) {
            eagerLoad = 1;
        } else if (strcmp(argv[i], "--no-audio") == 0) {
            noAudio = 1;
        } else if (strcmp(argv[i], "--rf-pin") == 0 && i + 1 < argc) {
            int pin = std::atoi(argv[++i]);
            if (pin < 0 || pin > 27) { fprintf(stderr, "Error: --rf-pin must be 0..27\n"); return -1; }
            rfPinOverride = (unsigned)pin;
        } else if (strcmp(argv[i], "--listen") == 0) {
            listenMode = 1;
        } else if (strcmp(argv[i], "--learn") == 0) {
            learnMode = 1;
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

    // learn jako listen zvuk nepotřebuje — na boxu bez zesilovače nemá být
    // hlasitý a bez zvukové karty se vůbec nesmí omezovat v registraci
    if (!listenMode && !learnMode && !noAudio) {
        if (SDL_Init(SDL_INIT_AUDIO) < 0) {
            fprintf(stderr, "Error: SDL audio init failed: %s\n", SDL_GetError());
            return -1;
        }
        if (Mix_OpenAudio(MIX_RATE, MIX_DEFAULT_FORMAT, 2, 1024) < 0) {
            fprintf(stderr, "Error: Mix_OpenAudio failed: %s\n", Mix_GetError());
            return -1;
        }
        Mix_AllocateChannels(MAX_BUTTONS);
        audioOk = 1;
    }

    if (!listenMode)
        loadMap(map);
    if (!listenMode && !learnMode && !noAudio && eagerLoad) {
        // Akční sloty (@restart) zvuk nemají, takže je přeskočit — jinak by
        // se pokusil Mix_LoadWAV na "@restart tracker.service" a hlásil
        // chybu na slot, který je v pořádku. Počítá se jen proti zvukovým.
        int loaded = 0, audio = 0;
        for (int i = 0; i < numSlots; i++) {
            if (!slots[i].restartUnits.empty()) continue;
            audio++;
            if (loadSample(i)) loaded++;
        }
        fprintf(stdout, "sample: %d/%d loaded from %s/\n", loaded, audio, samplesDir);
    } else if (!listenMode && !learnMode && !noAudio) {
        // Líné načítání: zvuk se rozjede jen při --eager, jinak se každý
        // vzorek načte až při prvním stisku jeho tlačítka.
        fprintf(stdout, "sample: lazy load from %s/ (first press per layer)\n",
                samplesDir);
    } else if (!listenMode && !learnMode) {
        fprintf(stdout, "sample: audio disabled (--no-audio)\n");
    }

    if (lcdEnabled) {
        if (lcdOpen() == 0) {
            if (learnMode) lcdLine(0, "BOX %c LEARN");
            else if (listenMode) lcdLine(0, "BOX %c LISTEN");
            else lcdStatusReady();
        } else {
            lcdEnabled = 0;
        }
    }

    fprintf(stdout,
            "sampler %s (box %c, %s, te=%dus, debounce=%llums, fade=%llums, rf=gpiochip0/%u%s)\n",
            VERSION_STRING, boxLetter,
            learnMode ? "learn" : (listenMode ? "listen" : "play"),
            teUs, (unsigned long long)(debounceUs / 1000ull),
            (unsigned long long)(fadeUs / 1000ull), rfPinOverride,
            (listenMode && confirmMin > 1) ? ", confirm" : "");
    if (listenMode && confirmMin > 1)
        fprintf(stdout, "confirm: %d frames in %llums required\n",
                confirmMin, (unsigned long long)(confirmWindowUs / 1000ull));
    fflush(stdout);

    if (learnMode) {
        fprintf(stdout,
                "learn: %d tlačítek v %s. Stiskni tlačítko, Enter = "
                "výchozí název, nebo text. 'q' = konec.\n",
                numSlots, mapPath);
        fflush(stdout);
    }

    int haveRf = 0;
    if (!simulateMode && !simulateRf) {
        haveRf = (rfInit() == 0);
        if (!haveRf) {
#if HAVE_GPIOD
            fprintf(stderr,
                    "Error: cannot open %s line %u: %s\n",
                    RF_CHIP, rfPinOverride, strerror(errno));
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
            // Tady nekalu smyčka sama (blokuje na stdin), takže rozfádění
            // musí odtiknout rovnou po stisku, jinak by v --simulate zůstalo
            // viset ticho do konce vstupu.
            fadesTick();
        }
        fadesTick();
    } else {
        while (running) {
            uint64_t t[32];
            int r[32];
            int n = rfDrain(t, r, 32);
            if (n == 0) {
                // v learn režimu čekáme i na 'q' z klávesnice — bez toho by se
                // dalo ukončit jen Ctrl-C, což na bezhlavém boxu nepohodlí
                if (learnMode) {
                    struct pollfd pfd;
                    pfd.fd = STDIN_FILENO;
                    pfd.events = POLLIN;
                    int pr = poll(&pfd, 1, 0);
                    if (pr > 0) {
                        char line[256];
                        if (learnReadLine(line, sizeof(line)) < 0) break;
                        if (strcmp(line, "q") == 0 || strcmp(line, "Q") == 0) {
                            learnQuit = 1;
                            break;
                        }
                    }
                }
                usleep(2000);
                // Rozfádění jde po stejném tiku jako čtení GPIO — hlavní
                // smyčka se jinak jen čeká, takže je to jediné místo, kde
                // je čas přesný a nemusí se volat SDL_GetTicks().
                fadesTick();
                continue;
            }
            for (int i = 0; i < n; i++) decoderPush(dec, t[i], r[i]);
            fadesTick();
        }
    }

    if (learnMode) {
        fprintf(stdout, "learn: %d tlačítek zapsáno do %s%s\n",
                numSlots, mapPath, learnQuit ? " (konec)" : "");
        fflush(stdout);
    }

#if HAVE_GPIOD
    if (rfLine) gpiod_line_release(rfLine);
    if (rfChip) gpiod_chip_close(rfChip);
#endif
    if (lcdFd >= 0) close(lcdFd);
    if (audioOk) {
        // Co pořád hraje, se na bezhlavém boxu jinak nepozná — sampler se
        // ukončuje signálem a poslední stisky nejsou nikde jinde vidět.
        // Hodí se to i v testu: dvě vrstvy po dvou stiscích musí být
        // vypnuté obě, ne jen ta poslední. V --listen/--learn nic nehraje,
        // takže je tenhle výpis prázdný a není potřeba ho nijak hlídat.
        int live = 0;
        std::string list;
        for (int i = 0; i < numSlots; i++) {
            if (Mix_Playing(slots[i].channel) != 0) {
                if (live++) list += ", ";
                list += slots[i].file;
            }
        }
        if (live)
            fprintf(stdout, "layers still playing: %d [%s]\n", live, list.c_str());
        for (int i = 0; i < numSlots; i++)
            if (slots[i].chunk) Mix_FreeChunk(slots[i].chunk);
        Mix_CloseAudio();
        SDL_Quit();
    }
    return 0;
}