#ifndef GIT_VERSION
#define GIT_VERSION "dev"
#endif
#define VERSION_STRING GIT_VERSION

#include <opencv2/opencv.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/calib3d.hpp>
#include <opencv2/core/utils/logger.hpp>
#ifdef GRAY
#undef GRAY
#endif
#include "raylib.h"
#include "rlgl.h"   // rlPushMatrix/rlScalef — škálování snímku na celý monitor
#include <SDL2/SDL.h>
#include <SDL2/SDL_mixer.h>
#include <iostream>
#include <vector>
#include <iterator>
#include <fstream>
#include <string>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <csignal>
#include <ctime>
#include <algorithm>
#include <thread>
#include <chrono>
#include <unistd.h>
#if HAVE_GPIOD
#include <gpiod.h>
#endif
#include "buttons.h"

#define CALIB_FILE "calib.txt"

// ── Dvě barevné koule nad hrací plochou ──────────────────────────────
// Všech 8 smyček (4 nálady + 3 intermezza + podklad track9) se nahraje a
// spustí naráz v nekonečné smyčce; hrají ale jen když je zapnutá interaction
// (tlačítko F = @interact). Když je vypnutá, jsou ztlumené = ticho.
// Koule do nich jen míchají hlasitost:
//   zelená   = 4 náladové stopy Interactive_* (rektifikovaná poloha X/Y ->
//              kvadranty),
//   červená  = 3 intermezza Inter_* (poloha vlevo/vpravo -> trojice pásem).
// Na boxu A jsou náladové stopy Interactive_music_{Y-up_WAR,Y-down_PEACE,
// X-left-DRAMA,X-right-INTIMACY}. Sledování je barevné (HSV blob) — na
// Pi 4 nestojí skoro nic, žádný MOG2 ani KCF, jen převod do HSV a pár
// prahů na snímek.
#define N_MOOD 4
#define N_INTER 3
#define N_BED 1
// Nejmenší plocha blobu, aby se počítal za kouli. Menší koule (zelená bývá
// menší než červená) dává jen pár desítek pixelů, takže vyšší práh ji zahodil.
#define BALL_MIN_AREA 8
#define BALL_LOST_FRAMES 12
#define BALL_SMOOTH_ALPHA 0.5f

// Výchozí rozlišení kamery. 1280x720 dá menší kouli víc pixelů (lepší
// detekce) za cenu vyššího CPU; jde přebít --width/--height.
#define CAM_W_DEFAULT 1280
#define CAM_H_DEFAULT 720

// Jak často nejvýš spouštět barevnou detekci (ms). Koule se hýbou pomalu,
// takže ~15 Hz stačí a ušetří to drtivou většinu CPU ve vysokém rozlišení.
// 0 = každý snímek (bez šetření).
#define DETECT_MS_DEFAULT 66
#define HANDLE_RADIUS 20.0f
#define GRID_DIV 8
#define VOL_SMOOTH_ALPHA 0.30f

// Naučená barva koule. Kliknutím do okna se vzorkuje HSV pixelu pod kurzorem
// (levé = zelená/nálady, pravé = červená/intermezza); detekce pak hledá
// odstín ±hueTol kolem té barvy, takže na konkrétní kouli zůstane citlivá
// i když se osvětlení/odstín liší od pevných prahů. Ukládá se do calib.txt.
#define HUE_TOL_DEFAULT 15
#define HUE_TOL_MIN 3
#define HUE_TOL_MAX 90

// Náladové stopy zelené koule (Interactive_*) — pořadí odpovídá kvadrantům:
// 0=nahoře (WAR), 1=dole (PEACE), 2=vlevo (DRAMA), 3=vpravo (INTIMACY).
static const char* moodFiles[N_MOOD] = {
    "samples/Interactive_music_Y-up_WAR.wav",
    "samples/Interactive_music_Y-down_PEACE.wav",
    "samples/Interactive_music_X-left-DRAMA.wav",
    "samples/Interactive_music_X-right-INTIMACY.wav",
};

// Intermezza červené koule (jména ASCII — "Čísla" by dělalo problém s
// kódováním napříč stroji; na boxu je soubor i pod původním jménem).
static const char* interFiles[N_INTER] = {
    "samples/Inter_Mobilizace_Cisla.wav",
    "samples/Inter_Emil_Hacha.wav",
    "samples/Inter_Mobilizace_Emoce.wav",
};

// Osmý „looping" vzorek — hraje jako podklad pod koulemi, když je interaction
// zapnutá. Dohromady tak v trackeru běží 8 smyček ve synchronu.
static const char* bedFiles[N_BED] = {
    "samples/track9.wav",
};

// ── 433 MHz přijímač SRX882S na GPIO15 ────────────────────────────────
// Dřív měl tracker vlastní miniaturní dekodér jen pro tlačítko F (restart).
// Teď je sampler sloučený do trackera: buttons.c přebírá celý EV1527 dekodér,
// map.csv a přehrávání vzorků. Tlačítko F je v mapě jako @interact (umlčí
// přehrávané vzorky a přepne interaction = smyčky); volitelně ho lze přes
// --reset-code nechat restartovat službu (původní chování). Pin přes --rf-pin,
// RF vypne --no-rf.
#define RF_GPIO_LINE 15
#define RF_CHIP "gpiochip0"

// Trvalé smyčky trackeru (4 nálady + 3 intermezza + 1 podklad) na kanálech
// 0..N_LOOP-1, vzorky z map.csv na kanálech od N_LOOP výš
// (viz buttons.setChannelBase). Smyčky hrají jen když je interaction zapnutá.
#define N_LOOP (N_MOOD + N_INTER + N_BED)
// Podklad hraje konstantní hlasitostí, když je interaction zapnutá.
#define LOOP_BED_VOLUME 110
#define MIX_RATE 24000   // stejné jako sampler a samples-decode.sh (mono 24 kHz)

static volatile sig_atomic_t g_quit = 0;

static void onSignal(int) { g_quit = 1; }

// Sampler přilepený k trackeru: jedno SDL_mixer, jedno GPIO15.
static ButtonEngine buttons;

static cv::Point2f corners[4];
// Rozlišení, pro které jsou rohy uložené. Při změně rozlišení kamery se rohy
// přepočítají, aby kalibrace plochy zůstala platná (viz loadCalib).
static int calibW = 0, calibH = 0;

// Naučená barva (HSV, OpenCV rozsahy) pro každou kouli; index = BallColor
// (BALL_RED=0, BALL_GREEN=1). Když set=false, použijí se původní pevné prahy.
struct ColorModel { bool set = false; int h = 0, s = 0, v = 0; };
static ColorModel ballColor[2];
static int hueTol = HUE_TOL_DEFAULT;
static int ballMinArea = BALL_MIN_AREA;   // --min-area, prah plochy blobu

static int nearestCorner(cv::Point2f p) {
    float bestD = HANDLE_RADIUS;
    int best = -1;
    for (int i = 0; i < 4; i++) {
        float d = cv::norm(p - corners[i]);
        if (d < bestD) { bestD = d; best = i; }
    }
    return best;
}

static void gridLines(cv::Mat& img, const cv::Mat& Hinv) {
    cv::Scalar col(255, 255, 255);
    for (int i = 1; i < GRID_DIV; i++) {
        float f = (float)i / GRID_DIV;
        std::vector<cv::Point2f> dst1, dst2;
        std::vector<cv::Point2f> s1 = {{f, 0}}, s2 = {{f, 1}};
        cv::perspectiveTransform(s1, dst1, Hinv);
        cv::perspectiveTransform(s2, dst2, Hinv);
        cv::line(img, dst1[0], dst2[0], col, 1);

        std::vector<cv::Point2f> h1, h2;
        std::vector<cv::Point2f> t1 = {{0, f}}, t2 = {{1, f}};
        cv::perspectiveTransform(t1, h1, Hinv);
        cv::perspectiveTransform(t2, h2, Hinv);
        cv::line(img, h1[0], h2[0], col, 1);
    }

    std::vector<cv::Point2f> sa, sb;
    cv::perspectiveTransform((std::vector<cv::Point2f>){{0.5f, 0}}, sa, Hinv);
    cv::perspectiveTransform((std::vector<cv::Point2f>){{0.5f, 1}}, sb, Hinv);
    cv::line(img, sa[0], sb[0], cv::Scalar(0, 255, 0), 2);
    cv::perspectiveTransform((std::vector<cv::Point2f>){{0, 0.5f}}, sa, Hinv);
    cv::perspectiveTransform((std::vector<cv::Point2f>){{1, 0.5f}}, sb, Hinv);
    cv::line(img, sa[0], sb[0], cv::Scalar(0, 255, 0), 2);
}

static void saveCalib() {
    std::ofstream f(CALIB_FILE);
    if (f) {
        for (int i = 0; i < 4; i++) f << corners[i].x << " " << corners[i].y << " ";
        f << "\n";
        // Druhý řádek: naučené barvy koulí (red, green) + citlivost.
        for (int c = 0; c < 2; c++)
            f << (ballColor[c].set ? 1 : 0) << " "
              << ballColor[c].h << " " << ballColor[c].s << " " << ballColor[c].v << " ";
        f << hueTol << "\n";
        // Třetí řádek: rozlišení, pro které jsou rohy uložené (pro přepočet
        // při jiném rozlišení kamery). Starší soubory ho nemají.
        if (calibW > 0 && calibH > 0) f << calibW << " " << calibH << "\n";
        f.close();
    }
}

static void loadCalib(int w, int h) {
    corners[0] = cv::Point2f(0, 0);
    corners[1] = cv::Point2f(w, 0);
    corners[2] = cv::Point2f(0, h);
    corners[3] = cv::Point2f(w, h);
    for (int c = 0; c < 2; c++) ballColor[c] = ColorModel{};
    hueTol = HUE_TOL_DEFAULT;
    std::ifstream f(CALIB_FILE);
    if (f) {
        for (int i = 0; i < 4; i++) f >> corners[i].x >> corners[i].y;
        // Starší soubory mají jen rohy; barvy pak zůstanou nenaučené.
        for (int c = 0; c < 2; c++) {
            int set = 0;
            if (!(f >> set)) break;
            ballColor[c].set = set != 0;
            f >> ballColor[c].h >> ballColor[c].s >> ballColor[c].v;
        }
        int t;
        if (f >> t) hueTol = std::clamp(t, HUE_TOL_MIN, HUE_TOL_MAX);
        // Rozlišení uložených rohů: z nového třetího řádku, jinak předpokládáme
        // starých 640x480 (než existoval --width/--height).
        int sw = 640, sh = 480;
        if (f >> sw >> sh) { /* nový formát */ }
        f.close();
        if (sw > 0 && sh > 0 && (sw != w || sh != h)) {
            float fx = (float)w / (float)sw;
            float fy = (float)h / (float)sh;
            for (int i = 0; i < 4; i++) {
                corners[i].x *= fx;
                corners[i].y *= fy;
            }
            std::cerr << "calib: rohy přepočítány z " << sw << "x" << sh
                      << " na " << w << "x" << h << std::endl;
        }
    }
    calibW = w;
    calibH = h;
}

// Maska hrací plochy = polygon z kalibrovaných rohů. Mimo něj koule nehrají.
// floorROI je bounding box té masky — detekce běží jen v něm (méně pixelů =
// rychlejší cvtColor/inRange/findContours, hlavně ve vysokém rozlišení).
static cv::Rect floorROI;
static void buildFloorMask(int w, int h, cv::Mat& mask) {
    mask = cv::Mat::zeros(h, w, CV_8UC1);
    std::vector<cv::Point> pts;
    for (int i = 0; i < 4; i++) pts.push_back(cv::Point((int)corners[i].x, (int)corners[i].y));
    cv::fillPoly(mask, std::vector<std::vector<cv::Point>>{pts}, cv::Scalar(255));
    cv::Rect r = cv::boundingRect(pts) & cv::Rect(0, 0, w, h);
    if (r.width < 1 || r.height < 1) r = cv::Rect(0, 0, w, h);
    floorROI = r;
}

// ── sledování koulí ──────────────────────────────────────────────────
// Každá koule je jen největší blob své barvy uvnitř masky plochy. Žádný
// klasifikátor: koule jsou barevně odlišené, takže HSV prahy stačí a na
// rozdíl od MOG2 to funguje i pro kouli, která se nehýbe.
struct Ball {
    bool present = false;
    int lost = 0;
    int zone = -1;              // kvadrant 0..3 v rektifikované ploše
    float sx = -1.0f, sy = -1.0f;   // vyhlazený střed (EMA)
    cv::Rect bbox;
};

enum BallColor { BALL_RED = 0, BALL_GREEN = 1 };

static bool detectBall(const cv::Mat& hsv, int color, const cv::Mat& mask, cv::Rect& out) {
    cv::Mat m1, m2, fg;
    const ColorModel& cm = ballColor[color];
    if (cm.set) {
        // Naučená barva: odstín ±hueTol (kolem 0/180 se obepíná), saturace
        // a jas stačí zlomek naučené hodnoty, aby koule zůstala chycená
        // i ve stínu / při jiném osvětlení. Malá koule má větší podíl
        // okrajových pixelů (míchaných s pozadím), proto jsou podlahy nízké.
        int sMin = std::max(25, cm.s / 4);
        int vMin = std::max(20, cm.v / 4);
        int lo = cm.h - hueTol;
        int hi = cm.h + hueTol;
        auto band = [&](int a, int b) {
            cv::Mat t;
            cv::inRange(hsv, cv::Scalar(a, sMin, vMin), cv::Scalar(b, 255, 255), t);
            return t;
        };
        if (lo < 0)        fg = band(lo + 180, 179) | band(0, hi);
        else if (hi > 179) fg = band(lo, 179) | band(0, hi - 180);
        else               fg = band(lo, hi);
    } else if (color == BALL_RED) {
        // Červená obepíná 0/180, takže dva intervaly.
        cv::inRange(hsv, cv::Scalar(0, 80, 50), cv::Scalar(12, 255, 255), m1);
        cv::inRange(hsv, cv::Scalar(158, 80, 50), cv::Scalar(180, 255, 255), m2);
        fg = m1 | m2;
    } else {
        // Výchozí zelená (dokud není naučená klikem): širší prahy, ať chytí
        // i menší/tmavší kouli. Odstín 35..90, nižší saturace i jas.
        cv::inRange(hsv, cv::Scalar(35, 45, 30), cv::Scalar(90, 255, 255), fg);
    }
    if (!mask.empty()) cv::bitwise_and(fg, mask, fg);

    // Malé koule: OPEN (eroze+dilatace) může drobný blob úplně smazat, proto
    // jen CLOSE (doplní dírky) a šum odfiltruje až práh --min-area.
    static const cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, {3, 3});
    cv::morphologyEx(fg, fg, cv::MORPH_CLOSE, kernel);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(fg, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    double best = ballMinArea;
    cv::Rect bestR;
    for (auto& c : contours) {
        double a = cv::contourArea(c);
        if (a < best) continue;
        best = a;
        bestR = cv::boundingRect(c);
    }
    if (bestR.empty()) return false;
    out = bestR;
    return true;
}

static void updateBall(Ball& b, bool found, const cv::Rect& r) {
    if (found) {
        float cx = (float)r.x + (float)r.width / 2.0f;
        float cy = (float)r.y + (float)r.height / 2.0f;
        if (b.sx < 0) { b.sx = cx; b.sy = cy; }
        else {
            b.sx += (cx - b.sx) * BALL_SMOOTH_ALPHA;
            b.sy += (cy - b.sy) * BALL_SMOOTH_ALPHA;
        }
        b.bbox = r;
        b.lost = 0;
        b.present = true;
    } else if (b.present && ++b.lost >= BALL_LOST_FRAMES) {
        b.present = false;
        b.zone = -1;
    }
}

// Střed koule -> rektifikované souřadnice plochy 0..1.
static void rectify(const cv::Mat& H, float cx, float cy, float& u, float& v) {
    std::vector<cv::Point2f> src = {{cx, cy}}, dst;
    cv::perspectiveTransform(src, dst, H);
    u = dst[0].x; v = dst[0].y;
    if (u < 0) u = 0; if (u > 1) u = 1;
    if (v < 0) v = 0; if (v > 1) v = 1;
}

// ── naučení barvy koule kliknutím ────────────────────────────────────
// Vezme pixel pod kurzorem (BGR snímek -> HSV) a uloží ho jako cílovou barvu
// koule. Detekce pak hledá odstín ±hueTol kolem této barvy.
static bool pickColor(const cv::Mat& bgr, int x, int y, int& h, int& s, int& v) {
    if (x < 0 || y < 0 || x >= bgr.cols || y >= bgr.rows) return false;
    cv::Vec3b px = bgr.at<cv::Vec3b>(y, x);
    cv::Mat one(1, 1, CV_8UC3, cv::Scalar(px[0], px[1], px[2])), hsv;
    cv::cvtColor(one, hsv, cv::COLOR_BGR2HSV);
    cv::Vec3b q = hsv.at<cv::Vec3b>(0, 0);
    h = q[0]; s = q[1]; v = q[2];
    return true;
}

static void teachColor(const cv::Mat& frame, int color, cv::Point2f mp) {
    int h, s, v;
    if (!pickColor(frame, (int)mp.x, (int)mp.y, h, s, v)) return;
    ballColor[color].set = true;
    ballColor[color].h = h; ballColor[color].s = s; ballColor[color].v = v;
    std::cerr << "color: " << (color == BALL_GREEN ? "green(mood)" : "red(inter)")
              << " <- h=" << h << " s=" << s << " v=" << v
              << " (tol +-" << hueTol << ")" << std::endl;
}

// HSV (OpenCV) -> raylib Color, pro vzorník naučené barvy v HUD.
static Color hsvToRgb(int h, int s, int v, unsigned char a = 255) {
    cv::Mat hsv(1, 1, CV_8UC3, cv::Scalar(h, s, v)), bgr;
    cv::cvtColor(hsv, bgr, cv::COLOR_HSV2BGR);
    cv::Vec3b p = bgr.at<cv::Vec3b>(0, 0);
    return (Color){p[2], p[1], p[0], a};
}

// ── 433 MHz přijímač (vlákno) ────────────────────────────────────────
static int rfPinOverride = RF_GPIO_LINE;
static bool rfEnabled = true;

#if HAVE_GPIOD
// Necítí proud: čeká na hranu s 20ms timeoutem, takže při klidovém
// přijímači jen spí a nekonkuruje trackerům o CPU. Dekódované kódy strká
// do fronty enginu; dispatch (přehrání vzorku) dělá až hlavní smyčka, aby
// se SDL_mixer nevolal ze dvou vláken.
static void rfThreadMain() {
    struct gpiod_chip* chip = gpiod_chip_open_by_name(RF_CHIP);
    if (!chip) return;
    struct gpiod_line* line = gpiod_chip_get_line(chip, rfPinOverride);
    if (!line) { gpiod_chip_close(chip); return; }
    if (gpiod_line_request_both_edges_events(line, "tracker") < 0) {
        gpiod_line_release(line);
        gpiod_chip_close(chip);
        return;
    }
    while (!g_quit) {
        struct timespec timeout = { 0, 20000000 };
        int ret = gpiod_line_event_wait(line, &timeout);
        if (ret < 0) break;
        if (ret == 0) continue;
        struct gpiod_line_event ev;
        if (gpiod_line_event_read(line, &ev) < 0) break;
        uint64_t t = (uint64_t)ev.ts.tv_sec * 1000000ull +
                     (uint64_t)ev.ts.tv_nsec / 1000ull;
        buttons.pushEvent(t, ev.event_type == GPIOD_LINE_EVENT_RISING_EDGE);
    }
    gpiod_line_release(line);
    gpiod_chip_close(chip);
}

static int rfInit() {
    struct gpiod_chip* chip = gpiod_chip_open_by_name(RF_CHIP);
    if (!chip) return -1;
    struct gpiod_line* line = gpiod_chip_get_line(chip, rfPinOverride);
    if (!line) { gpiod_chip_close(chip); return -1; }
    if (gpiod_line_request_both_edges_events(line, "tracker-probe") < 0) {
        gpiod_line_release(line);
        gpiod_chip_close(chip);
        return -1;
    }
    gpiod_line_release(line);
    gpiod_chip_close(chip);
    return 0;
}
#else
static int rfInit() { return -1; }
#endif

int main(int argc, char* argv[]) {
    bool headless = false;
    bool noAudio = false;
    bool simulate = false;
    const char* mapPath = "map.csv";
    const char* samplesDir = "samples";
    int teUs = 320;
    int debounceMs = 2000;
    int fadeMs = 2000;
    int stopFadeMs = 300;
    int reqWidth = CAM_W_DEFAULT;
    int reqHeight = CAM_H_DEFAULT;
    int detectMs = DETECT_MS_DEFAULT;
    uint32_t resetCode = 0;      // 0 = off; map.csv wins (F = @interact)
    bool allowRestart = false;
    bool dryRun = false;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-v") == 0) {
            std::cout << "tracker " VERSION_STRING << std::endl;
            return 0;
        }
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            std::cout << "tracker " VERSION_STRING << std::endl;
            std::cout << "usage: tracker [options]" << std::endl;
            std::cout << "  --headless, -H   run without a window (systemd / Box A)" << std::endl;
            std::cout << "  --map FILE       RF code->sample map (default: map.csv)\n"
                         "  --samples-dir D  sample directory (default: samples)\n"
                         "  --allow-restart  honour @stopall/@restart action slots (needs root)\n"
                         "  --dry-run        with --allow-restart, print but do not run\n"
                         "  --fade-ms N      fade-in of a triggered layer (default 2000)\n"
                         "  --stop-fade-ms N fade-out for @stopall (default 300)\n"
                         "  --debounce-ms N  per-button debounce window (default 2000)\n"
                         "  --te-us N        EV1527 base timing in microseconds (default 320)\n";
            std::cout << "  --reset-code N   RF code that restarts the service (default off;\n"
                         "                   0 = map.csv decides, e.g. F = @interact)" << std::endl;
            std::cout << "  --rf-pin N       BCM line of the 433 MHz receiver (default "
                      << RF_GPIO_LINE << ")" << std::endl;
            std::cout << "  --width N        capture width (default " << CAM_W_DEFAULT << ")\n"
                         "  --height N       capture height (default " << CAM_H_DEFAULT << ")\n";
            std::cout << "  --min-area N     min blob area for a ball (default "
                      << BALL_MIN_AREA << ")\n";
            std::cout << "  --detect-ms N    max CV detection rate in ms (default "
                      << DETECT_MS_DEFAULT << "; 0 = every frame)\n";
            std::cout << "  --no-rf          do not read the 433 MHz receiver" << std::endl;
            std::cout << "  --no-audio       skip audio init (decode and act, play nothing)\n"
                         "  --simulate       read RF codes from stdin instead of GPIO15\n";
            std::cout << "  --version, -v    print version" << std::endl;
            std::cout << "Dvě koule: zelená míchá " << N_MOOD
                      << " náladové stopy Interactive_*, červená míchá " << N_INTER
                      << " intermezza Inter_*, osmou smyčkou je podklad track9. "
                      << "Všech " << N_LOOP
                      << " smyček hraje, jen když je interaction zapnutá "
                      << "tlačítkem F (@interact v mapě); RF tlačítka nad ně "
                      << "přidávají vzorky z map.csv." << std::endl;
            return 0;
        }
        if (strcmp(argv[i], "--headless") == 0 || strcmp(argv[i], "-H") == 0) {
            headless = true;
        }
        if (strcmp(argv[i], "--reset-code") == 0 && i + 1 < argc) {
            resetCode = (uint32_t)strtoul(argv[i + 1], NULL, 10);
            i++;
        }
        if (strcmp(argv[i], "--rf-pin") == 0 && i + 1 < argc) {
            rfPinOverride = std::atoi(argv[i + 1]);
            i++;
        }
        if (strcmp(argv[i], "--no-rf") == 0) {
            rfEnabled = false;
        }
        if (strcmp(argv[i], "--no-audio") == 0) {
            noAudio = true;
        }
        if (strcmp(argv[i], "--simulate") == 0) {
            simulate = true;
        }
        if (strcmp(argv[i], "--map") == 0 && i + 1 < argc) {
            mapPath = argv[++i];
        }
        if (strcmp(argv[i], "--samples-dir") == 0 && i + 1 < argc) {
            samplesDir = argv[++i];
        }
        if (strcmp(argv[i], "--allow-restart") == 0) {
            allowRestart = true;
        }
        if (strcmp(argv[i], "--dry-run") == 0) {
            dryRun = true;
        }
        if (strcmp(argv[i], "--fade-ms") == 0 && i + 1 < argc) {
            fadeMs = std::atoi(argv[++i]);
        }
        if (strcmp(argv[i], "--stop-fade-ms") == 0 && i + 1 < argc) {
            stopFadeMs = std::atoi(argv[++i]);
        }
        if (strcmp(argv[i], "--debounce-ms") == 0 && i + 1 < argc) {
            debounceMs = std::atoi(argv[++i]);
        }
        if (strcmp(argv[i], "--te-us") == 0 && i + 1 < argc) {
            teUs = std::atoi(argv[++i]);
        }
        if (strcmp(argv[i], "--min-area") == 0 && i + 1 < argc) {
            ballMinArea = std::atoi(argv[++i]);
            if (ballMinArea < 1) ballMinArea = 1;
        }
        if (strcmp(argv[i], "--width") == 0 && i + 1 < argc) {
            reqWidth = std::atoi(argv[++i]);
        }
        if (strcmp(argv[i], "--height") == 0 && i + 1 < argc) {
            reqHeight = std::atoi(argv[++i]);
        }
        if (strcmp(argv[i], "--detect-ms") == 0 && i + 1 < argc) {
            detectMs = std::atoi(argv[++i]);
        }
        // Zpětná kompatibilita se starým CLI (--max-people N, --tracker kcf):
        // počet koulí je teď pevně daný (červená + zelená), sledovač barevný.
        if ((strcmp(argv[i], "--max-people") == 0 || strcmp(argv[i], "--tracker") == 0)
            && i + 1 < argc) {
            i++;
        }
    }

    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);

    // Bez kamery OpenCV chrli na každý pokus otevřít /dev/video0 WARN řádky
    // ("can't open camera by index"); ticho na ERROR, ať nezaplevelíme journal.
    // Vlastní stav ("camera: opening/failed") hlásíme sami.
    cv::utils::logging::setLogLevel(cv::utils::logging::LOG_LEVEL_ERROR);

    // ── sampler přilepený k trackeru ──────────────────────────────────
    buttons.setBoxLetter('A');
    buttons.setMapPath(mapPath);
    buttons.setSamplesDir(samplesDir);
    buttons.setTeUs(teUs);
    buttons.setDebounceMs(debounceMs);
    buttons.setFadeMs(fadeMs);
    buttons.setStopFadeMs(stopFadeMs);
    buttons.setAllowRestart(allowRestart);
    buttons.setDryRun(dryRun);
    buttons.setResetCode(resetCode);
    buttons.setChannelBase(N_LOOP);   // smyčky 0..N_LOOP-1, vzorky od N_LOOP

    // ── zvuk: jedno SDL_mixer pro smyčky i vzorky ─────────────────────
    int mixCh = N_LOOP;
    Mix_Chunk* chunks[N_LOOP] = {0};
    if (!noAudio) {
        SDL_Init(SDL_INIT_AUDIO);
        if (Mix_OpenAudio(MIX_RATE, MIX_DEFAULT_FORMAT, 2, 1024) != 0) {
            // Bez zvukové karty raději nepuštit dál — otevřený PCM by stejně
            // zemřel. Exit -> Restart=always to zkusí znovu, až karta dorazí.
            std::cerr << "Error: audio open failed: " << Mix_GetError() << std::endl;
            return -1;
        }
        Mix_AllocateChannels(N_LOOP + BUTTONS_MAX_SLOTS);
        buttons.setAudioOk(true);

        // Všech 8 smyček nahrajeme a spustíme naráz (Mix_PlayChannel s -1 =
        // nekonečná smyčka); hlasitost pak míchají koule, RF vzorky hrají nad
        // tím. Smyčky jsou ztlumené, dokud není interaction zapnutá (F).
        for (int i = 0; i < N_MOOD; i++) {
            chunks[i] = Mix_LoadWAV(moodFiles[i]);
            if (!chunks[i]) std::cerr << "audio: missing " << moodFiles[i] << std::endl;
        }
        for (int i = 0; i < N_INTER; i++) {
            chunks[N_MOOD + i] = Mix_LoadWAV(interFiles[i]);
            if (!chunks[N_MOOD + i]) std::cerr << "audio: missing " << interFiles[i] << std::endl;
        }
        for (int i = 0; i < N_BED; i++) {
            chunks[N_MOOD + N_INTER + i] = Mix_LoadWAV(bedFiles[i]);
            if (!chunks[N_MOOD + N_INTER + i])
                std::cerr << "audio: missing " << bedFiles[i] << std::endl;
        }
        for (int i = 0; i < mixCh; i++) {
            Mix_Volume(i, 0);
            if (chunks[i]) Mix_PlayChannel(i, chunks[i], -1);
        }

        // Spec, který SDL2_mixer opravdu otevřelo, a přes který driver.
        int freq = 0, chans = 0;
        Uint16 fmt = 0;
        Mix_QuerySpec(&freq, &fmt, &chans);
        const char* drv = SDL_GetCurrentAudioDriver();
        std::cerr << "audio: " << (drv ? drv : "?") << " " << freq << " Hz, "
                  << chans << " channel(s)" << std::endl;
    } else {
        buttons.setAudioOk(false);
        std::cerr << "audio: disabled (--no-audio)" << std::endl;
    }

    // Mapa RF kódů -> vzorky (a akční sloty @stopall/@restart).
    buttons.loadMap();

    // ── 433 MHz přijímač (vlákno) ─────────────────────────────────────
    std::thread rfThread;
#if HAVE_GPIOD
    if (rfEnabled && !simulate) {
        if (rfInit() == 0) {
            rfThread = std::thread(rfThreadMain);
            std::cerr << "rf: listening on " << RF_CHIP << " line " << rfPinOverride
                      << " (map " << buttons.slotCount() << " slot(s))" << std::endl;
        } else {
            std::cerr << "rf: receiver unavailable (" << RF_CHIP << " line "
                      << rfPinOverride << " busy or missing); no buttons"
                      << std::endl;
        }
    } else if (!rfEnabled) {
        std::cerr << "rf: disabled (--no-rf)" << std::endl;
    }
#else
    if (rfEnabled && !simulate)
        std::cerr << "rf: built without libgpiod; no buttons" << std::endl;
#endif

    // ── --simulate: kódy ze stdin, bez kamery a bez GPIO ──────────────
    // F (@interact) ovládá jen hlasitost smyček, takže tu jen sledujeme stav.
    bool interactive = false;   // F: vypnuto = ticho, zapnuto = smyčky hrají
    if (simulate) {
        char line[512];
        while (!g_quit && fgets(line, sizeof(line), stdin)) {
            char* p = line;
            while (*p == ' ' || *p == '\t') p++;
            if (*p == '#' || *p == '\n' || *p == '\0') continue;
            buttons.onCode((uint32_t)strtoul(p, NULL, 10));
            buttons.fadesTick();
            if (buttons.takeInteract()) {
                interactive = !interactive;
                std::cerr << "interaction: " << (interactive ? "on" : "off")
                          << std::endl;
            }
        }
        buttons.fadesTick();
        g_quit = 1;
        if (rfThread.joinable()) rfThread.join();
        if (!noAudio) {
            for (int i = 0; i < mixCh; i++) if (chunks[i]) Mix_FreeChunk(chunks[i]);
            Mix_CloseAudio();
            SDL_Quit();
        }
        return 0;
    }

    // ── kamera (volitelná v headless) ─────────────────────────────────
    // Když kamera chybí, tracker běží dál (zvuk + RF tlačítka) a kameru
    // zkouší otevřít každé ~2 s. Bez tohohle by služba bez kamery spadla
    // a tlačítka by nefungovala.
    cv::VideoCapture cap;
    cv::Mat frame;
    int frameWidth = 0, frameHeight = 0;
    bool camReady = false;
    Font font = {0};
    float scale = 1.0f;
    float offX = 0.0f, offY = 0.0f;
    Image raylibImage = {0};
    Texture2D videoTex = {0};

    auto openCamera = [&]() -> bool {
        if (!cap.isOpened()) {
            cap.open(0);
            if (cap.isOpened()) {
                // MJPG dovolí 1280x720 (i vyšší) po USB2; když to kamera
                // neumí, OpenCV set tiše ignoruje a zvolí výchozí formát.
                cap.set(cv::CAP_PROP_FOURCC,
                        cv::VideoWriter::fourcc('M', 'J', 'P', 'G'));
                cap.set(cv::CAP_PROP_FRAME_WIDTH, reqWidth);
                cap.set(cv::CAP_PROP_FRAME_HEIGHT, reqHeight);
            }
        }
        if (!cap.isOpened()) return false;
        frame = cv::Mat();
        cap >> frame;
        if (frame.empty()) return false;
        frameWidth = frame.cols;
        frameHeight = frame.rows;
        loadCalib(frameWidth, frameHeight);
        raylibImage = Image{frame.data, frameWidth, frameHeight, 1,
                            PIXELFORMAT_UNCOMPRESSED_R8G8B8};
        return true;
    };

    if (!headless) {
        // Okenní režim je na kalibraci — bez kamery nemá smysl.
        if (!openCamera()) {
            std::cerr << "Error: Could not open video capture device." << std::endl;
            return -1;
        }
        camReady = true;

        InitWindow(frameWidth, frameHeight, "Tracker " VERSION_STRING);
        SetTargetFPS(60);
        // Na HDMI konzoli má být obraz na celé TV, takže okno natáhnu na celý
        // monitor. NE přes FLAG_FULLSCREEN_MODE: ten si vybere "nejbližší video
        // režim" (640x480) a na Raspberry Pi přepne výstup — tam GLX vizuály
        // nejsou a okno vůbec nevznikne.
        int mon = GetCurrentMonitor();
        if (mon >= 0) {
            int monW = GetMonitorWidth(mon);
            int monH = GetMonitorHeight(mon);
            if (monW > 0 && monH > 0
                && (monW != frameWidth || monH != frameHeight)) {
                SetWindowSize(monW, monH);
                SetWindowPosition(0, 0);
            }
        }
        int outW = GetScreenWidth();
        int outH = GetScreenHeight();
        // 4:3 snímek na 16:9 monitor svisle (pillarbox), ať koule nejsou elipsy.
        if (outW > 0 && outH > 0) {
            scale = (float)outW / (float)frameWidth;
            if ((float)outH / (float)frameHeight < scale) {
                scale = (float)outH / (float)frameHeight;
            }
            offX = ((float)outW - frameWidth * scale) / 2.0f;
            offY = ((float)outH - frameHeight * scale) / 2.0f;
            std::cerr << "  okno " << outW << "x" << outH
                      << ", snímek " << frameWidth << "x" << frameHeight
                      << " x" << scale << " na (" << (int)offX << "," << (int)offY << ")" << std::endl;
        }
        font = LoadFontEx("terminus.ttf", 20, NULL, 0);
        if (font.texture.id <= 0) font = GetFontDefault();
        else SetTextureFilter(font.texture, TEXTURE_FILTER_POINT);
    }

    std::cerr << "tracker " VERSION_STRING << " start: "
              << (headless ? "headless" : "window") << ", "
              << (camReady ? "camera " : "no camera yet, waiting, ")
              << "balls green(4 mood)+red(" << N_INTER << " inter) volume-mixed, "
              << mixCh << " loop (interaction off until F) + "
              << BUTTONS_MAX_SLOTS << " button channel(s), "
              << buttons.slotCount() << " RF slot(s), "
              << reqWidth << "x" << reqHeight << " capture, "
              << (detectMs > 0 ? std::to_string(1000 / std::max(1, detectMs)) + "Hz detect"
                               : std::string("detect every frame"))
              << std::endl;

    cv::Mat rgbFrame;
    cv::Mat hsvFrame;           // jeden HSV pro obě koule (reuse bufferu)
    bool dragging = false;
    int dragIdx = -1;

    // Homografie i maska podlahy závisí jen na rozích kalibrace, takže se
    // přepočítají jen když je kalibrace "špinavá" — ne na každém snímku.
    cv::Mat H, Hinv, floorMask;
    bool calibDirty = true;

    Ball red, green;            // green = 4 náladové stopy, red = 3 intermezza

    // Kameru zkoušíme otevřít nejvýš každé 2 s — cap.open() sám blokuje
    // ~0.5 s a bez throttlingu by pokusy zaplavily CPU i journal.
    auto lastCamTry = std::chrono::steady_clock::now() - std::chrono::seconds(10);
    bool camWarned = false;
    // Detekci (nejdražší část) pouštíme nejvýš každých detectMs milisekund.
    auto lastDetect = std::chrono::steady_clock::now() - std::chrono::hours(1);

    while (headless ? !g_quit : (!WindowShouldClose() && !g_quit)) {
        if (buttons.takeRestart()) {
            std::cerr << "tracker: restart on RF code" << std::endl;
            break;
        }
        buttons.processPending();
        buttons.fadesTick();
        if (buttons.takeInteract()) {
            interactive = !interactive;
            std::cerr << "interaction: " << (interactive ? "on" : "off")
                      << std::endl;
        }

        if (!camReady) {
            auto now = std::chrono::steady_clock::now();
            if (now - lastCamTry < std::chrono::seconds(2)) {
                usleep(50000);
                continue;
            }
            lastCamTry = now;
            if (openCamera()) {
                camReady = true;
                camWarned = false;
                std::cerr << "camera: opened (" << frameWidth << "x"
                          << frameHeight << ")" << std::endl;
            } else if (!camWarned) {
                std::cerr << "camera: not found, retrying every 2s "
                             "(tracker runs without video)" << std::endl;
                camWarned = true;
            }
            continue;
        }

        cap >> frame;
        if (frame.empty()) {
            std::cerr << "camera: frame empty, reconnecting" << std::endl;
            cap.release();
            camReady = false;
            continue;
        }
        raylibImage.data = frame.data;

        if (calibDirty) {
            cv::Point2f src[4] = {corners[0], corners[1], corners[2], corners[3]};
            cv::Point2f dst[4] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};
            H = cv::getPerspectiveTransform(src, dst);
            Hinv = H.inv();
            buildFloorMask(frameWidth, frameHeight, floorMask);
            calibDirty = false;
        }

        // ── koule (barevný blob) ───────────────────────────────────────────
        // HSV se počítá jednou pro obě koule (dřív 2x cvtColor na snímek) a
        // detekce běží jen v bounding boxu plochy (floorROI), ne v celém
        // snímku — na 1280x720 to citelně ubere práci. Navíc jen každých
        // detectMs ms (koule se hýbou pomalu), zbytek snímků se jen vykreslí.
        auto detNow = std::chrono::steady_clock::now();
        bool doDetect = detectMs <= 0 ||
            std::chrono::duration_cast<std::chrono::milliseconds>(detNow - lastDetect).count() >= detectMs;
        if (doDetect) {
            lastDetect = detNow;
            cv::cvtColor(frame, hsvFrame, cv::COLOR_BGR2HSV);
            cv::Rect roi = floorROI;
            cv::Mat hsvRoi = hsvFrame(roi);
            cv::Mat maskRoi = floorMask(roi);
            cv::Rect rb, gb;
            bool rFound = detectBall(hsvRoi, BALL_RED, maskRoi, rb);
            bool gFound = detectBall(hsvRoi, BALL_GREEN, maskRoi, gb);
            if (rFound) { rb.x += roi.x; rb.y += roi.y; }
            if (gFound) { gb.x += roi.x; gb.y += roi.y; }
            updateBall(red, rFound, rb);
            updateBall(green, gFound, gb);
        }

        // ── hlasitost: smyčky hrají jen když je interaction zapnutá ────────
        // Vypnutá interaction = ticho (F ztlumí všechny smyčky); zapnutá
        // interaction míchá 4 nálady + 3 intermezza podle koulí a k tomu
        // hraje osmý podkladový track konstantní hlasitostí.
        if (!interactive) {
            for (int ch = 0; ch < N_LOOP; ch++)
                if (Mix_Volume(ch, -1) != 0) Mix_Volume(ch, 0);
        } else {
        // ── hlasitost: zelená koule do 4 náladových stop (Interactive_*) ───
        float tgt[N_MOOD] = {0, 0, 0, 0};
        if (green.present) {
            float u, v;
            rectify(H, green.sx, green.sy, u, v);
            tgt[0] += (float)(1.0 - v);   // Y nahoře -> track1 (WAR)
            tgt[1] += (float)v;           // Y dole   -> track2 (PEACE)
            tgt[2] += (float)(1.0 - u);   // X vlevo  -> track3 (DRAMA)
            tgt[3] += (float)u;           // X vpravo -> track4 (INTIMACY)
        }
        for (int ch = 0; ch < N_MOOD; ch++) {
            if (tgt[ch] > 1.0f) tgt[ch] = 1.0f;
            int target = (int)(tgt[ch] * 128.0f);
            int cur = Mix_Volume(ch, -1);
            int next = (int)(cur + (float)(target - cur) * VOL_SMOOTH_ALPHA);
            if (target == 0 && cur < 2) next = 0;   // bez šumu v tichu
            if (next > 128) next = 128;
            if (next < 0) next = 0;
            Mix_Volume(ch, next);
        }

        // ── hlasitost: červená koule do 3 intermezzových stop (Inter_*) ────
        // Tři intermezza sedí ve třech svislých pásmech; koule mezi nimi
        // plynule prolíná (trojúhelníková váha, na okraji pásma nula).
        float itgt[N_INTER] = {0, 0, 0};
        if (red.present) {
            float u, v;
            rectify(H, red.sx, red.sy, u, v);
            for (int i = 0; i < N_INTER; i++) {
                float c = ((float)i + 0.5f) / (float)N_INTER;
                float w = 1.0f - fabsf(u - c) * (float)N_INTER;
                if (w > 0.0f) itgt[i] = w;
            }
        }
        for (int i = 0; i < N_INTER; i++) {
            int ch = N_MOOD + i;
            if (itgt[i] > 1.0f) itgt[i] = 1.0f;
            int target = (int)(itgt[i] * 128.0f);
            int cur = Mix_Volume(ch, -1);
            int next = (int)(cur + (float)(target - cur) * VOL_SMOOTH_ALPHA);
            if (target == 0 && cur < 2) next = 0;   // bez šumu v tichu
            if (next > 128) next = 128;
            if (next < 0) next = 0;
            Mix_Volume(ch, next);
        }

        // Osmý podkladový track hraje konstantně, dokud je interaction zapnutá.
        Mix_Volume(N_MOOD + N_INTER, LOOP_BED_VOLUME);
        }

        if (!headless) {
            if (IsKeyPressed(KEY_S)) saveCalib();
            if (IsKeyPressed(KEY_R)) { loadCalib(frameWidth, frameHeight); calibDirty = true; }
            if (IsKeyPressed(KEY_C)) {
                ballColor[BALL_RED] = ColorModel{};
                ballColor[BALL_GREEN] = ColorModel{};
                saveCalib();
                std::cerr << "color: cleared (pevné prahy)" << std::endl;
            }
            if (IsKeyPressed(KEY_LEFT_BRACKET)) {
                hueTol = std::max(HUE_TOL_MIN, hueTol - 2);
                saveCalib();
            }
            if (IsKeyPressed(KEY_RIGHT_BRACKET)) {
                hueTol = std::min(HUE_TOL_MAX, hueTol + 2);
                saveCalib();
            }

            // Myš je v souřadnicích okna, kalibrace v souřadnicích snímku.
            Vector2 mouse = GetMousePosition();
            float mx = ((float)mouse.x - offX) / scale;
            float my = ((float)mouse.y - offY) / scale;
            if (mx >= 0 && my >= 0 && mx < frameWidth && my < frameHeight) {
                cv::Point2f mp(mx, my);
                // Pravé tlačítko: nauč barvu červené (inter) koule.
                if (IsMouseButtonPressed(MOUSE_BUTTON_RIGHT)) {
                    teachColor(frame, BALL_RED, mp);
                    saveCalib();
                }
                if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT)) {
                    // Na rohu kalibrace se táhne; jinde klik naučí zelenou kouli.
                    dragIdx = nearestCorner(mp);
                    if (dragIdx >= 0) dragging = true;
                    else { teachColor(frame, BALL_GREEN, mp); saveCalib(); }
                } else if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) {
                    dragging = false;
                }
                if (dragging && dragIdx >= 0) {
                    corners[dragIdx] = mp;
                    calibDirty = true;
                }
            } else {
                dragging = false;
            }
        }

        if (!headless) {
            cv::cvtColor(frame, rgbFrame, cv::COLOR_BGR2RGB);
            gridLines(rgbFrame, Hinv);
            raylibImage.data = rgbFrame.data;

            // Texturu vytvoříme jednou a dál do ní jen nahráváme pixely.
            // LoadTextureFromImage každý snímek by znovu alokoval GPU texturu.
            if (videoTex.id == 0) videoTex = LoadTextureFromImage(raylibImage);
            else UpdateTexture(videoTex, rgbFrame.data);

            BeginDrawing();
            ClearBackground(BLACK);
            rlPushMatrix();
            rlTranslatef(offX, offY, 0.0f);
            rlScalef(scale, scale, 1.0f);
            DrawTexture(videoTex, 0, 0, WHITE);

            for (int i = 0; i < 4; i++) {
                Color c = (i < 2) ? (Color){255, 80, 80, 255} : (Color){80, 80, 255, 255};
                DrawCircle((int)corners[i].x, (int)corners[i].y, 8, c);
            }

            // Červená = nálady, zelená = intermezza. Rámeček jen když koule
            // zrovna je (nebo chvíli byla); jinak hlášení "lost".
            // Barva rámečku = naučená barva koule (jinak výchozí zelená/červená).
            Color rDraw = ballColor[BALL_RED].set
                ? hsvToRgb(ballColor[BALL_RED].h, ballColor[BALL_RED].s, ballColor[BALL_RED].v)
                : RED;
            Color gDraw = ballColor[BALL_GREEN].set
                ? hsvToRgb(ballColor[BALL_GREEN].h, ballColor[BALL_GREEN].s, ballColor[BALL_GREEN].v)
                : GREEN;

            // Červená = intermezza, zelená = nálady. Rámeček jen když koule
            // zrovna je (nebo chvíli byla); jinak hlášení "lost".
            if (red.present) {
                DrawRectangleLinesEx(
                    (Rectangle){(float)red.bbox.x, (float)red.bbox.y,
                                (float)red.bbox.width, (float)red.bbox.height},
                    3.0f, rDraw);
                DrawTextEx(font, "R", {(float)red.bbox.x, (float)red.bbox.y - 20},
                           18, 0.0f, rDraw);
            } else {
                DrawTextEx(font, "R lost", {20, 60}, 18, 0.0f, rDraw);
            }
            if (green.present) {
                DrawRectangleLinesEx(
                    (Rectangle){(float)green.bbox.x, (float)green.bbox.y,
                                (float)green.bbox.width, (float)green.bbox.height},
                    3.0f, gDraw);
                DrawTextEx(font, "G", {(float)green.bbox.x, (float)green.bbox.y - 20},
                           18, 0.0f, gDraw);
            } else {
                DrawTextEx(font, "G lost", {20, 90}, 18, 0.0f, gDraw);
            }

            // Vzorník naučených barev (plný = naučeno, dutý = výchozí prahy).
            int swX = frameWidth - 34;
            DrawCircle(swX, 34, 12, gDraw);
            if (!ballColor[BALL_GREEN].set) DrawCircleLines(swX, 34, 12, WHITE);
            DrawTextEx(font, "G", {(float)(swX - 40), 24}, 18, 0.0f, gDraw);
            DrawCircle(swX, 70, 12, rDraw);
            if (!ballColor[BALL_RED].set) DrawCircleLines(swX, 70, 12, WHITE);
            DrawTextEx(font, "R", {(float)(swX - 40), 60}, 18, 0.0f, rDraw);
            DrawTextEx(font, TextFormat("sens +-%d", hueTol),
                {(float)(frameWidth - 150), 92}, 14, 0.0f, RAYWHITE);

            int barH = 60;
            int barW = frameWidth / mixCh;
            int barY = frameHeight - barH - 10;
            for (int i = 0; i < mixCh; i++) {
                int vol = Mix_Volume(i, -1);
                float fill = (float)vol / 128.0f;
                int bx = i * barW + 5;
                int bw = barW - 10;
                Color c = (i < N_MOOD) ? GREEN
                         : (i < N_MOOD + N_INTER) ? RED : BLUE;
                DrawRectangle(bx, barY, bw, barH, (Color){c.r, c.g, c.b, 40});
                DrawRectangle(bx, barY + barH - (int)(fill * barH), bw, (int)(fill * barH), c);
                DrawRectangleLines(bx, barY, bw, barH, WHITE);
                const char* lbl = (i < N_MOOD) ? TextFormat("T%d", i + 1)
                                : (i < N_MOOD + N_INTER)
                                      ? TextFormat("I%d", i - N_MOOD + 1)
                                      : "B";
                DrawTextEx(font, lbl, {(float)(bx + 4), (float)(barY + 2)}, 14, 0.0f, WHITE);
            }

            Color iCol = interactive ? GREEN : GRAY;
            DrawTextEx(font, TextFormat("interaction: %s", interactive ? "ON" : "OFF"),
                {(float)(frameWidth - 200), (float)(frameHeight - 108)}, 18, 0.0f, iCol);

            DrawTextEx(font, "F = interaction on/off | [ ] sens | S save | R reset | C clear",
                {10, 10}, 16, 0.0f, RAYWHITE);
            DrawTextEx(font, "left-click=teach G  right-click=teach R",
                {10, 30}, 16, 0.0f, RAYWHITE);
            DrawTextEx(font, "green=4 Interactive tracks  red=3 Inter  B=track9 (bed)",
                {10, (float)(frameHeight - 80)}, 16, 0.0f, RAYWHITE);

            rlPopMatrix();
            EndDrawing();
        }
    }

    std::cerr << "tracker " VERSION_STRING << " stop" << std::endl;
    // RF vlákno končí na g_quit.
    g_quit = 1;
    if (rfThread.joinable()) rfThread.join();
    if (!headless) {
        if (videoTex.id != 0) UnloadTexture(videoTex);
        UnloadFont(font);
        CloseWindow();
    }
    if (!noAudio) {
        for (int i = 0; i < mixCh; i++) if (chunks[i]) Mix_FreeChunk(chunks[i]);
        Mix_CloseAudio();
        SDL_Quit();
    }
    cap.release();
    return 0;
}
