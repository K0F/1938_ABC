#ifndef GIT_VERSION
#define GIT_VERSION "dev"
#endif
#define VERSION_STRING GIT_VERSION

#include "grayskull.h"   // tiny C vision (blobs, morfologie, perspektiva)
#include "v4l2_cam.h"    // V4L2 webkamera (MJPEG/libjpeg, YUYV), bez OpenCV
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
#include <cmath>
#include <thread>
#include <chrono>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
#include <unistd.h>
#if HAVE_GPIOD
#include <gpiod.h>
#endif
#include "buttons.h"

// ── Drobné náhrady typů, které dřív dělalo OpenCV ────────────────────
struct Pt { float x = 0, y = 0; };                       // bod (souřadnice snímku)
struct Box { int x = 0, y = 0, w = 0, h = 0;             // obdélník (bbox blobu)
             bool empty() const { return w <= 0 || h <= 0; } };
struct Mat3 { double m[9]; };                            // homografie, řádkově

static inline float dist2(const Pt& a, const Pt& b) {
    float dx = a.x - b.x, dy = a.y - b.y;
    return dx * dx + dy * dy;
}

// RGB (0..255) -> HSV ve stejných rozsazích jako OpenCV: H 0..179 (stupně/2),
// S,V 0..255. Držíme se OpenCV konvence, aby starší calib.txt (naučené barvy
// uložené jako OpenCV HSV) zůstal platný.
static inline void rgbToHsv(int r, int g, int b, int& h, int& s, int& v) {
    int mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    int mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    v = mx;
    int d = mx - mn;
    s = mx == 0 ? 0 : (d * 255) / mx;
    if (d == 0) { h = 0; return; }
    float hue;
    if (mx == r)      hue = 60.0f * ((g - b) / (float)d);
    else if (mx == g) hue = 60.0f * ((b - r) / (float)d) + 120.0f;
    else              hue = 60.0f * ((r - g) / (float)d) + 240.0f;
    if (hue < 0) hue += 360.0f;
    h = (int)(hue / 2.0f);
    if (h > 179) h = 179;
}

// HSV (OpenCV rozsahy) -> raylib Color, pro vzorník naučené barvy v HUD.
static Color hsvToRgb(int h, int s, int v, unsigned char a = 255) {
    float H = (float)h * 2.0f, S = s / 255.0f, V = v / 255.0f;
    float C = V * S;
    float X = C * (1.0f - std::fabs(std::fmod(H / 60.0f, 2.0f) - 1.0f));
    float m = V - C;
    float r = 0, g = 0, b = 0;
    if      (H < 60)  { r = C; g = X; }
    else if (H < 120) { r = X; g = C; }
    else if (H < 180) { g = C; b = X; }
    else if (H < 240) { g = X; b = C; }
    else if (H < 300) { r = X; b = C; }
    else              { r = C; b = X; }
    return (Color){(unsigned char)((r + m) * 255.0f),
                   (unsigned char)((g + m) * 255.0f),
                   (unsigned char)((b + m) * 255.0f), a};
}

#define CALIB_FILE "calib.txt"

// ── Dvě barevné koule nad hrací plochou ──────────────────────────────
// Všech 8 smyček (4 nálady + 4 intermezza) se nahraje a spustí naráz v
// nekonečné smyčce; hrají ale jen když je zapnutá interaction (tlačítko F =
// @interact). Když je vypnutá, jsou ztlumené = ticho.
// Koule do nich jen míchají hlasitost:
//   zelená   = 4 náladové stopy Interactive_* (rektifikovaná poloha X/Y ->
//              kvadranty, plynulý 2D crossfade),
//   červená  = 4 intermezza Inter_* (kvadrant -> tvrdý on/off switch).
// Na boxu A jsou náladové stopy Interactive_music_{Y-up_WAR,Y-down_PEACE,
// X-left-DRAMA,X-right-INTIMACY}. Sledování je barevné (HSV blob) — na
// Pi 4 nestojí skoro nic, žádný MOG2 ani KCF, jen převod do HSV a pár
// prahů na snímek.
#define N_MOOD 4
// I1-I4: Inter_Mobilizace_Cisla, Inter_Emil_Hacha, Inter_Mobilizace_Emoce
// a podklad track9 (dřív samostatný "bed") — viz interFiles níže.
#define N_INTER 4
// Nejmenší plocha blobu, aby se počítal za kouli. Menší koule (zelená bývá
// menší než červená) dává jen pár desítek pixelů, takže vyšší práh ji zahodil.
#define BALL_MIN_AREA 8
#define BALL_LOST_FRAMES 12
// Koule je kruh, takže tvar filtrujeme: příliš protáhlé/nerovné blobu jsou
// odlesky nebo pozadí. circularita = 4π·obsah / obvod² (1 = kruh).
#define BALL_MIN_ROUNDNESS 0.45f
// Maximální plocha blobu (0 = bez limitu). Chrání proti chycení velkého
// stejně barevného objektu v pozadí.
#define BALL_MAX_AREA 0
// "Gate": když je koule zamčená, přijmeme jen blob do téhle vzdálenosti
// (px) od predikovaného středu — zamezí přeskočení na jiný objekt. Ztracená
// koule hledá globálně (gate se neuplatní), takže se zase chytne.
#define BALL_GATE_PX 220.0f
// Jak rychle (EMA) se naučená saturace/jas přizpůsobují skutečnému blobu,
// aby detekce nespadla při změně expozice. Odstín zůstává naučený.
#define BALL_ADAPT_ALPHA 0.02f
// Šum Kalmanu (v px²): větší KF_MEAS_NOISE = hlazší ale pomalejší; menší =
// svižnější. KF_POS_NOISE/KF_VEL_NOISE řídí, jak rychle filtr věří změně.
#define KF_MEAS_NOISE 9.0f
#define KF_POS_NOISE 0.2f
#define KF_VEL_NOISE 2.0f
// Ztracená koule (present, ale mimo gate) se hledá nejdřív v tomhle okruhu
// kolem poslední známé polohy, a až pak globálně (největší blob). Zamezí to
// přeskočení na jiný stejně barevný objekt; 0 = rovnou globálně.
#define BALL_REACQUIRE_PX 420.0f

// ── Odstranění pozadí (clean plate) ──────────────────────────────────
// Prázdná plocha (koule mimo stůl) se uloží jako referenční snímek; detekce
// pak bere jen pixely, které se od reference liší (a zároveň mají barvu
// koule). Zmizí statické odlesky a barevné předměty v pozadí, ale koule
// zůstane detekovaná i když se nehýbe (na rozdíl od MOG2). Srovnáváme
// maximální rozdíl kanálu (ne šedotón), aby barva podobného jasu (červená na
// dřevě) nezmizela; dilatace toleruje drobné posuny/šum.
#define BG_DIFF_DEFAULT 25
#define BG_FRAMES 15
#define BG_FILE_DEFAULT "bg.bin"

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
// I4 je podklad track9 (dřív samostatný „bed"), takže dohromady běží 8 smyček
// ve synchronu (4 nálady T + 4 intermezza I).
static const char* interFiles[N_INTER] = {
    "samples/Inter_Mobilizace_Cisla.wav",
    "samples/Inter_Emil_Hacha.wav",
    "samples/Inter_Mobilizace_Emoce.wav",
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

// Trvalé smyčky trackeru (4 nálady + 4 intermezza) na kanálech
// 0..N_LOOP-1, vzorky z map.csv na kanálech od N_LOOP výš
// (viz buttons.setChannelBase). Smyčky hrají jen když je interaction zapnutá.
#define N_LOOP (N_MOOD + N_INTER)
// Čtyři náladové stopy (první čtyři vzorky trackeru) jedou na čtvrtinu
// hlasitosti, aby nepřebíjely jednorázové vzorky z map.csv (RF tlačítka),
// které zůstávají na plné 1.0.
#define LOOP_MOOD_VOLUME 0.25f
#define MIX_RATE 24000   // stejné jako sampler a samples-decode.sh (mono 24 kHz)

static volatile sig_atomic_t g_quit = 0;

static void onSignal(int) { g_quit = 1; }

// Sampler přilepený k trackeru: jedno SDL_mixer, jedno GPIO15.
static ButtonEngine buttons;

static Pt corners[4];
// Rozlišení, pro které jsou rohy uložené. Při změně rozlišení kamery se rohy
// přepočítají, aby kalibrace plochy zůstala platná (viz loadCalib).
static int calibW = 0, calibH = 0;

// Naučená barva (HSV, OpenCV rozsahy) pro každou kouli; index = BallColor
// (BALL_RED=0, BALL_GREEN=1). Když set=false, použijí se původní pevné prahy.
struct ColorModel { bool set = false; int h = 0, s = 0, v = 0; };
static ColorModel ballColor[2];
static int hueTol = HUE_TOL_DEFAULT;
static int ballMinArea = BALL_MIN_AREA;   // --min-area, prah plochy blobu
static int ballMaxArea = BALL_MAX_AREA;   // --max-area, 0 = bez limitu
static float ballMinRoundness = BALL_MIN_ROUNDNESS;  // --min-roundness
static float ballGatePx = BALL_GATE_PX;   // --gate-px, 0 = bez gate
static float ballAdaptAlpha = BALL_ADAPT_ALPHA;      // --adapt-alpha
static float ballReacquirePx = BALL_REACQUIRE_PX;    // --reacquire-px
static const char* camDevice = "/dev/video0";        // --device

// Referenční snímek prázdné plochy pro odstranění pozadí (bg.bin, RGB).
static std::vector<unsigned char> bgRefRgb;   // w*h*3, R8G8B8
static bool bgRefOn = false;      // je platná reference načtená?
static bool bgEnabled = true;     // --no-bg vypne odstranění pozadí úplně
static int bgDiffThresh = BG_DIFF_DEFAULT;   // --bg-diff, práh (max kanál)
static bool bgWarned = false;     // už jsme hlásili chybějící referenci?

// ── homografie (nahrazuje cv::getPerspectiveTransform/perspectiveTransform) ──
// 3x3 matice zobrazení snímek -> jednotkový čtverec (a zpět). Počítá se jen při
// změně kalibrace, takže i jednoduchý Gauss stačí.
static inline void applyH(const Mat3& H, double x, double y, float& ox, float& oy) {
    double w = H.m[6] * x + H.m[7] * y + H.m[8];
    if (std::fabs(w) < 1e-12) w = 1e-12;
    ox = (float)((H.m[0] * x + H.m[1] * y + H.m[2]) / w);
    oy = (float)((H.m[3] * x + H.m[4] * y + H.m[5]) / w);
}

static Mat3 homography4(const Pt src[4], const Pt dst[4]) {
    double a[8][9];
    for (int i = 0; i < 4; i++) {
        double x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y;
        double* r0 = a[2 * i];
        double* r1 = a[2 * i + 1];
        r0[0]=x; r0[1]=y; r0[2]=1; r0[3]=0; r0[4]=0; r0[5]=0; r0[6]=-u*x; r0[7]=-u*y; r0[8]=u;
        r1[0]=0; r1[1]=0; r1[2]=0; r1[3]=x; r1[4]=y; r1[5]=1; r1[6]=-v*x; r1[7]=-v*y; r1[8]=v;
    }
    for (int c = 0; c < 8; c++) {
        int piv = c;
        for (int r = c + 1; r < 8; r++)
            if (std::fabs(a[r][c]) > std::fabs(a[piv][c])) piv = r;
        if (piv != c)
            for (int k = c; k < 9; k++) std::swap(a[c][k], a[piv][k]);
        double p = a[c][c];
        if (std::fabs(p) < 1e-12) continue;
        for (int k = c; k < 9; k++) a[c][k] /= p;
        for (int r = 0; r < 8; r++) {
            if (r == c) continue;
            double f = a[r][c];
            if (f == 0) continue;
            for (int k = c; k < 9; k++) a[r][k] -= f * a[c][k];
        }
    }
    Mat3 H;
    for (int i = 0; i < 8; i++) H.m[i] = a[i][8];
    H.m[8] = 1.0;
    return H;
}

static Mat3 invert3(const Mat3& H) {
    const double* m = H.m;
    double det = m[0]*(m[4]*m[8]-m[5]*m[7])
               - m[1]*(m[3]*m[8]-m[5]*m[6])
               + m[2]*(m[3]*m[7]-m[4]*m[6]);
    if (std::fabs(det) < 1e-12) det = 1e-12;
    double id = 1.0 / det;
    Mat3 r;
    r.m[0]=(m[4]*m[8]-m[5]*m[7])*id; r.m[1]=(m[2]*m[7]-m[1]*m[8])*id; r.m[2]=(m[1]*m[5]-m[2]*m[4])*id;
    r.m[3]=(m[5]*m[6]-m[3]*m[8])*id; r.m[4]=(m[0]*m[8]-m[2]*m[6])*id; r.m[5]=(m[2]*m[3]-m[0]*m[5])*id;
    r.m[6]=(m[3]*m[7]-m[4]*m[6])*id; r.m[7]=(m[1]*m[6]-m[0]*m[7])*id; r.m[8]=(m[0]*m[4]-m[1]*m[3])*id;
    return r;
}

static int nearestCorner(Pt p) {
    float bestD = HANDLE_RADIUS * HANDLE_RADIUS;
    int best = -1;
    for (int i = 0; i < 4; i++) {
        float d = dist2(p, corners[i]);
        if (d < bestD) { bestD = d; best = i; }
    }
    return best;
}

// Mřížka plochy: 8 dílků + středové osy. Kreslí se raylibem přes texturu
// (dřív se pekla do snímku). Hinv zobrazuje jednotkový čtverec -> snímek.
static void drawGrid(const Mat3& Hinv) {
    for (int i = 1; i < GRID_DIV; i++) {
        float f = (float)i / GRID_DIV, x1, y1, x2, y2;
        applyH(Hinv, f, 0, x1, y1); applyH(Hinv, f, 1, x2, y2);
        DrawLine((int)x1, (int)y1, (int)x2, (int)y2, (Color){255, 255, 255, 90});
        applyH(Hinv, 0, f, x1, y1); applyH(Hinv, 1, f, x2, y2);
        DrawLine((int)x1, (int)y1, (int)x2, (int)y2, (Color){255, 255, 255, 90});
    }
    float x1, y1, x2, y2;
    applyH(Hinv, 0.5f, 0, x1, y1); applyH(Hinv, 0.5f, 1, x2, y2);
    DrawLine((int)x1, (int)y1, (int)x2, (int)y2, (Color){0, 255, 0, 160});
    applyH(Hinv, 0, 0.5f, x1, y1); applyH(Hinv, 1, 0.5f, x2, y2);
    DrawLine((int)x1, (int)y1, (int)x2, (int)y2, (Color){0, 255, 0, 160});
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
    corners[0] = Pt{0, 0};
    corners[1] = Pt{(float)w, 0};
    corners[2] = Pt{0, (float)h};
    corners[3] = Pt{(float)w, (float)h};
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

// Maska hrací plochy = čtyřúhelník z kalibrovaných rohů (0/255, celý snímek).
// floorROI je jeho bounding box — detekce běží jen v něm (méně pixelů =
// rychlejší). Rohy jsou uložené jako TL,TR,BL,BR (kvůli homografii), pro výplň
// je řadíme do správného pořadí TL,TR,BR,BL.
static std::vector<unsigned char> floorMaskFull;
static Box floorROI;
static void buildFloorMask(int w, int h) {
    floorMaskFull.assign((size_t)w * h, 0);
    Pt poly[4] = {corners[0], corners[1], corners[3], corners[2]};
    int minx = w - 1, miny = h - 1, maxx = 0, maxy = 0;
    for (int i = 0; i < 4; i++) {
        minx = std::min(minx, (int)corners[i].x);
        maxx = std::max(maxx, (int)corners[i].x);
        miny = std::min(miny, (int)corners[i].y);
        maxy = std::max(maxy, (int)corners[i].y);
    }
    minx = std::max(0, minx); miny = std::max(0, miny);
    maxx = std::min(w - 1, maxx); maxy = std::min(h - 1, maxy);
    if (maxx < minx || maxy < miny) { floorROI = Box{0, 0, w, h}; return; }
    for (int y = miny; y <= maxy; y++) {
        for (int x = minx; x <= maxx; x++) {
            bool in = false;
            for (int i = 0, j = 3; i < 4; j = i++) {
                float xi = poly[i].x, yi = poly[i].y, xj = poly[j].x, yj = poly[j].y;
                if (((yi > y) != (yj > y)) &&
                    (x < (xj - xi) * (y - yi) / (yj - yi) + xi))
                    in = !in;
            }
            if (in) floorMaskFull[(size_t)y * w + x] = 255;
        }
    }
    floorROI = Box{minx, miny, maxx - minx + 1, maxy - miny + 1};
}

// ── odstranění pozadí: reference prázdné plochy ──────────────────────
// Formát: "P6\n<w> <h>\n255\n" + w*h*3 bajtů RGB (binární PPM). Psaní/čtení
// přes ofstream/ifstream, bez OpenCV. Ukládáme RGB (ne šedotón), aby rozdíl
// chytil i barevně odlišný objekt se stejným jasem.
static bool saveBgRef(const char* path, const unsigned char* rgb, int w, int h) {
    if (!rgb || w <= 0 || h <= 0) return false;
    std::ofstream f(path, std::ios::binary);
    if (!f) return false;
    f << "P6\n" << w << " " << h << "\n255\n";
    f.write(reinterpret_cast<const char*>(rgb), (std::streamsize)w * h * 3);
    return (bool)f;
}

static bool loadBgRef(const char* path, int w, int h) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::string magic;
    int gw = 0, gh = 0, maxv = 0;
    f >> magic >> gw >> gh >> maxv;
    if (magic != "P6" || gw <= 0 || gh <= 0 || maxv <= 0) return false;
    f.get();   // jedna bílá mezera za hlavičkou
    std::vector<unsigned char> g((size_t)gw * gh * 3);
    f.read(reinterpret_cast<char*>(g.data()), (std::streamsize)g.size());
    if (!f) return false;
    if (gw != w || gh != h) {
        // Jiné rozlišení kamery: převzorkuj nejbližším sousedem (reference je
        // rozmazaná, hrubé převzorkování stačí).
        std::vector<unsigned char> r((size_t)w * h * 3);
        for (int y = 0; y < h; y++) {
            int sy = (int)((long)y * gh / h);
            for (int x = 0; x < w; x++) {
                int sx = (int)((long)x * gw / w);
                const unsigned char* s = &g[((size_t)sy * gw + sx) * 3];
                unsigned char* d = &r[((size_t)y * w + x) * 3];
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
            }
        }
        bgRefRgb.swap(r);
        std::cerr << "bg: reference přepočítána z " << gw << "x" << gh
                  << " na " << w << "x" << h << std::endl;
    } else {
        bgRefRgb.swap(g);
    }
    bgRefOn = true;
    std::cerr << "bg: reference načtena z " << path << " (" << w << "x" << h
              << ")" << std::endl;
    return true;
}

// Maska pixelů, které se liší od reference prázdné plochy (max rozdíl kanálu
// > thresh), zředěná 3x3 dilatací. Bez reference vrací nullptr a volající
// spadne na čistě barevnou detekci.
static std::vector<unsigned char> bgFgBuf;
static const unsigned char* buildFgMask(const unsigned char* rgb, int w, int h,
                                        int thresh) {
    if (!bgRefOn || !rgb || (int)bgRefRgb.size() < w * h * 3) return nullptr;
    size_t N = (size_t)w * h;
    if (bgFgBuf.size() < N) bgFgBuf.resize(N);
    for (size_t i = 0, p = 0; i < N; i++, p += 3) {
        int d0 = std::abs((int)rgb[p]     - (int)bgRefRgb[p]);
        int d1 = std::abs((int)rgb[p + 1] - (int)bgRefRgb[p + 1]);
        int d2 = std::abs((int)rgb[p + 2] - (int)bgRefRgb[p + 2]);
        int d = d0 > d1 ? (d0 > d2 ? d0 : d2) : (d1 > d2 ? d1 : d2);
        bgFgBuf[i] = (d > thresh) ? 255 : 0;
    }
    // Dilatace 3x3 (max okolí) do pomocného bufferu.
    static std::vector<unsigned char> dil;
    dil.assign(bgFgBuf.begin(), bgFgBuf.end());
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            unsigned char m = 0;
            for (int dy = -1; dy <= 1 && !m; dy++) {
                int yy = y + dy; if (yy < 0 || yy >= h) continue;
                for (int dx = -1; dx <= 1; dx++) {
                    int xx = x + dx; if (xx < 0 || xx >= w) continue;
                    if (bgFgBuf[(size_t)yy * w + xx]) { m = 255; break; }
                }
            }
            dil[(size_t)y * w + x] = m;
        }
    }
    bgFgBuf.swap(dil);
    return bgFgBuf.data();
}

// ── sledování koulí ──────────────────────────────────────────────────
// Každá koule je nejlepší blob své barvy uvnitř masky plochy. Žádný
// klasifikátor: koule jsou barevně odlišené, takže HSV prahy stačí a na
// rozdíl od MOG2 to funguje i pro kouli, která se nehýbe.
//
// Střed bereme z minEnclosingCircle (robustní vůči dírám od odlesku), tvar
// filtrujeme kruhovostí a zamčená koule musí být blízko predikce (gate).
// Polohu vyhlazuje drobný 1D Kalman s konstantní rychlostí (zvlášť X a Y):
// hlazuje šum, ale nezavléká a při krátkém výpadku chvíli předpovídá.
struct CVKalman1D {
    float p = 0, v = 0;
    float P00 = 1, P01 = 0, P10 = 0, P11 = 1;
    bool init = false;
    void reset(float pos) {
        p = pos; v = 0; P00 = 1; P01 = P10 = 0; P11 = 1; init = true;
    }
    void predict(float dt) {
        if (!init) return;
        p += v * dt;
        float n00 = P00 + dt * (P10 + P01) + dt * dt * P11 + KF_POS_NOISE;
        float n01 = P01 + dt * P11;
        float n10 = P10 + dt * P11;
        float n11 = P11 + KF_VEL_NOISE;
        P00 = n00; P01 = n01; P10 = n10; P11 = n11;
    }
    void correct(float z) {
        if (!init) { reset(z); return; }
        float S = P00 + KF_MEAS_NOISE;
        float K0 = P00 / S, K1 = P10 / S;
        float innov = z - p;
        p += K0 * innov;
        v += K1 * innov;
        float n00 = (1 - K0) * P00, n01 = (1 - K0) * P01;
        float n10 = P10 - K1 * P00, n11 = P11 - K1 * P01;
        P00 = n00; P01 = n01; P10 = n10; P11 = n11;
    }
};

struct Ball {
    bool present = false;
    int lost = 0;
    int zone = -1;              // kvadrant 0..3 v rektifikované ploše
    float sx = -1.0f, sy = -1.0f;   // vyhlazený/predikovaný střed
    Box bbox;
    CVKalman1D kx, ky;
    void predict(float dt) {
        if (!kx.init) return;
        kx.predict(dt); ky.predict(dt);
        sx = kx.p; sy = ky.p;
    }
    void correct(float cx, float cy, const Box& r) {
        kx.correct(cx); ky.correct(cy);
        sx = kx.p; sy = ky.p;
        bbox = r; lost = 0; present = true;
    }
    void miss() {
        if (++lost >= BALL_LOST_FRAMES) {
            present = false; zone = -1;
            kx.init = false; ky.init = false;
        }
    }
};

enum BallColor { BALL_RED = 0, BALL_GREEN = 1 };

// Buffery pro grayskull (alokují se jednou, jen rostou podle potřeby).
static std::vector<unsigned char> g_maskBuf, g_tmpBuf, g_sBuf, g_vBuf;
static std::vector<gs_label> g_labBuf;
static std::vector<gs_blob> g_blobBuf;

// Najde kouli dané barvy v ROI "roi" snímku rgb (fw x fh, R8G8B8). floorMask
// (fw*fh, 0/255) omezí hledání na hrací plochu, volitelný fgMask (stejný
// layout, může být nullptr) navíc vyloučí pixely shodné s prázdnou plochou.
// Vrací true a vyplní
// outCenter/outBox (souřadnice snímku) a střední saturaci/jas blobu.
//
// Kandidáty dělá grayskull (spojité komponenty); tvar filtrujeme poměrem stran
// bboxu a zaplněním (odfiltruje odlesky a protáhlé fleky). Asociace je po
// vrstvách, aby koule "nepřeskočila" na jiný objekt daleko od predikce.
static bool detectBall(const unsigned char* rgb, int fw, int fh,
                       const unsigned char* floorMask, const unsigned char* fgMask,
                       int color, const Box& roi,
                       Pt prev, float gatePx, float reacquirePx, Pt avoid,
                       Pt& outCenter, Box& outBox, float* meanS, float* meanV) {
    int rw = roi.w, rh = roi.h;
    if (rw < 1 || rh < 1) return false;
    size_t N = (size_t)rw * rh;
    g_maskBuf.assign(N, 0);
    g_sBuf.assign(N, 0);
    g_vBuf.assign(N, 0);

    const ColorModel& cm = ballColor[color];
    const bool learned = cm.set;
    int sMin, vMin;
    if (learned)       { sMin = std::max(25, cm.s / 4); vMin = std::max(20, cm.v / 4); }
    else if (color == BALL_RED) { sMin = 80; vMin = 50; }
    else               { sMin = 45; vMin = 30; }

    for (int ry = 0; ry < rh; ry++) {
        const unsigned char* rp = rgb + ((size_t)(roi.y + ry) * fw + roi.x) * 3;
        const unsigned char* fm = floorMask
            ? floorMask + (size_t)(roi.y + ry) * fw + roi.x : nullptr;
        const unsigned char* gm = fgMask
            ? fgMask + (size_t)(roi.y + ry) * fw + roi.x : nullptr;
        unsigned char* mp = g_maskBuf.data() + (size_t)ry * rw;
        unsigned char* sp = g_sBuf.data() + (size_t)ry * rw;
        unsigned char* vp = g_vBuf.data() + (size_t)ry * rw;
        for (int rx = 0; rx < rw; rx++, rp += 3, mp++, sp++, vp++) {
            if (fm && !fm[rx]) continue;
            if (gm && !gm[rx]) continue;   // stejné jako prázdná plocha
            int H, S, V; rgbToHsv(rp[0], rp[1], rp[2], H, S, V);
            if (S < sMin || V < vMin) continue;
            bool match;
            if (learned) {
                int d = H - cm.h; if (d < 0) d = -d;
                if (d > 90) d = 180 - d;          // odstín se obepíná přes 0/180
                match = d <= hueTol;
            } else if (color == BALL_RED) {
                match = (H <= 12 || H >= 158);
            } else {
                match = (H >= 35 && H <= 90);
            }
            if (match) { *mp = 255; *sp = (unsigned char)S; *vp = (unsigned char)V; }
        }
    }

    // CLOSE = dilatace + eroze (doplní dírky od odlesku), přes grayskull.
    g_tmpBuf.assign(N, 0);
    gs_image im{(unsigned)rw, (unsigned)rh, g_maskBuf.data()};
    gs_image it{(unsigned)rw, (unsigned)rh, g_tmpBuf.data()};
    gs_dilate(it, im);
    gs_erode(im, it);

    const unsigned cap = 4096;
    if (g_labBuf.size() < N) g_labBuf.resize(N);
    if (g_blobBuf.size() < cap) g_blobBuf.resize(cap);
    unsigned nb = gs_blobs(im, g_labBuf.data(), g_blobBuf.data(), cap);

    const bool hasPrev = prev.x >= 0.0f;
    const bool hasAvoid = avoid.x >= 0.0f;
    bool haveNear = false, haveReacq = false, haveAny = false;
    float bestNear = 0, bestReacq = 0, bestArea = 0;
    Pt cNear, cReacq, cAny;
    Box rNear, rReacq, rAny;
    gs_label lNear = 0, lReacq = 0, lAny = 0;
    for (unsigned i = 0; i < nb; i++) {
        const gs_blob& bl = g_blobBuf[i];
        float a = (float)bl.area;
        if (a < (float)ballMinArea) continue;
        if (ballMaxArea > 0 && a > (float)ballMaxArea) continue;
        int bw = (int)bl.box.w, bh = (int)bl.box.h;
        double aspect = (double)std::min(bw, bh) / (double)std::max(bw, bh);
        double fill = (double)a / (double)(bw * bh);
        if (aspect < (double)ballMinRoundness) continue;   // protáhlé (odlesk)
        if (fill < 0.45) continue;                         // řídké (odlesk)
        Box box{roi.x + (int)bl.box.x, roi.y + (int)bl.box.y, bw, bh};
        // Střed z bboxu (ne z těžiště) — dírka od odlesku mění těžiště, ale ne
        // krajní body, takže bbox zůstává vystředěný na kouli.
        Pt ctr{(float)(box.x + box.w / 2), (float)(box.y + box.h / 2)};
        float dPrev = 1e30f, dAvoid = 1e30f;
        if (hasPrev) { float dx = ctr.x - prev.x, dy = ctr.y - prev.y; dPrev = std::sqrt(dx*dx+dy*dy); }
        if (hasAvoid) { float dx = ctr.x - avoid.x, dy = ctr.y - avoid.y; dAvoid = std::sqrt(dx*dx+dy*dy); }
        if (hasPrev && hasAvoid && dAvoid < dPrev) continue;  // patří druhé kouli
        if (hasPrev && gatePx > 0 && dPrev <= gatePx && (!haveNear || dPrev < bestNear)) {
            bestNear = dPrev; cNear = ctr; rNear = box; lNear = bl.label; haveNear = true;
        }
        if (hasPrev && reacquirePx > 0 && dPrev <= reacquirePx && (!haveReacq || dPrev < bestReacq)) {
            bestReacq = dPrev; cReacq = ctr; rReacq = box; lReacq = bl.label; haveReacq = true;
        }
        if (!haveAny || a > bestArea) {
            bestArea = a; cAny = ctr; rAny = box; lAny = bl.label; haveAny = true;
        }
    }
    gs_label lbl;
    if (haveNear)       { outCenter = cNear;  outBox = rNear;  lbl = lNear; }
    else if (haveReacq) { outCenter = cReacq; outBox = rReacq; lbl = lReacq; }
    else if (haveAny)   { outCenter = cAny;   outBox = rAny;   lbl = lAny; }
    else return false;

    if (meanS || meanV) {
        unsigned long ss = 0, vv = 0; unsigned area = 0;
        for (int ry = 0; ry < rh; ry++) {
            const gs_label* lp = g_labBuf.data() + (size_t)ry * rw;
            for (int rx = 0; rx < rw; rx++) {
                if (lp[rx] != lbl) continue;
                ss += g_sBuf[(size_t)ry * rw + rx];
                vv += g_vBuf[(size_t)ry * rw + rx];
                area++;
            }
        }
        if (area) {
            if (meanS) *meanS = (float)(ss / area);
            if (meanV) *meanV = (float)(vv / area);
        }
    }
    return true;
}

// Střed koule -> rektifikované souřadnice plochy 0..1.
static void rectify(const Mat3& H, float cx, float cy, float& u, float& v) {
    applyH(H, cx, cy, u, v);
    if (u < 0) u = 0; if (u > 1) u = 1;
    if (v < 0) v = 0; if (v > 1) v = 1;
}

// ── naučení barvy koule kliknutím ────────────────────────────────────
// Vezme průměr barev v malém okně (5x5) kolem kliknutého pixelu a uloží
// ho jako cílovou barvu koule. Průměr z okna je odolnější než jediný pixel
// (ten může padnout na odlesk nebo šum). Detekce pak hledá odstín ±hueTol.
static bool pickColor(const unsigned char* rgb, int fw, int fh, int x, int y,
                      int& h, int& s, int& v) {
    if (x < 0 || y < 0 || x >= fw || y >= fh) return false;
    const int R = 2;
    int x0 = std::max(0, x - R), y0 = std::max(0, y - R);
    int x1 = std::min(fw - 1, x + R), y1 = std::min(fh - 1, y + R);
    // Odstín se průměruje vektorově (přes úhel na kružnici), aby se správně
    // zprůměroval i kolem 0/180.
    double sx = 0, sy = 0, ss = 0, sv = 0;
    int n = 0;
    for (int yy = y0; yy <= y1; yy++) {
        const unsigned char* rp = rgb + ((size_t)yy * fw + x0) * 3;
        for (int xx = x0; xx <= x1; xx++, rp += 3) {
            int hh, ssv, vv; rgbToHsv(rp[0], rp[1], rp[2], hh, ssv, vv);
            double ang = hh * M_PI / 90.0;   // 0..180 -> 0..2π
            sx += std::cos(ang); sy += std::sin(ang);
            ss += ssv; sv += vv; n++;
        }
    }
    if (n == 0) return false;
    double ang = std::atan2(sy, sx);
    if (ang < 0) ang += 2.0 * M_PI;
    h = (int)std::lround(ang * 90.0 / M_PI);
    if (h >= 180) h -= 180;
    s = (int)std::lround(ss / n);
    v = (int)std::lround(sv / n);
    return true;
}

static void teachColor(const unsigned char* rgb, int fw, int fh, int color, Pt mp) {
    int h, s, v;
    if (!pickColor(rgb, fw, fh, (int)mp.x, (int)mp.y, h, s, v)) return;
    ballColor[color].set = true;
    ballColor[color].h = h; ballColor[color].s = s; ballColor[color].v = v;
    std::cerr << "color: " << (color == BALL_GREEN ? "green(mood)" : "red(inter)")
              << " <- h=" << h << " s=" << s << " v=" << v
              << " (tol +-" << hueTol << ")" << std::endl;
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
    bool lockExposure = false;   // --lock-exposure, vypne auto-expozici/WB
    const char* bgFile = BG_FILE_DEFAULT;   // --bg, reference prázdné plochy

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
                         "  --height N       capture height (default " << CAM_H_DEFAULT << ")\n"
                         "  --device PATH    V4L2 camera device (default /dev/video0)\n";
            std::cout << "  --min-area N     min blob area for a ball (default "
                      << BALL_MIN_AREA << ")\n";
            std::cout << "  --max-area N     max blob area, 0 = no limit (default "
                      << BALL_MAX_AREA << ")\n"
                         "  --min-roundness F min blob roundness 0..1 (default "
                      << BALL_MIN_ROUNDNESS << ")\n";
            std::cout << "  --gate-px N      lock gate radius in px, 0 = off (default "
                      << (int)BALL_GATE_PX << ")\n";
            std::cout << "  --adapt-alpha F  learned S/V adaptation rate (default "
                      << BALL_ADAPT_ALPHA << ")\n";
            std::cout << "  --reacquire-px N lost-ball search radius in px (default "
                      << (int)BALL_REACQUIRE_PX << ")\n"
                         "  --bg FILE        empty-floor reference image (default "
                      << BG_FILE_DEFAULT << ")\n"
                         "  --bg-diff N      background diff threshold, max channel (default "
                      << BG_DIFF_DEFAULT << ")\n"
                         "  --no-bg          disable background removal\n";
            std::cout << "  --lock-exposure  turn off camera auto-exposure/WB\n";
            std::cout << "  --detect-ms N    max CV detection rate in ms (default "
                      << DETECT_MS_DEFAULT << "; 0 = every frame)\n";
            std::cout << "  --no-rf          do not read the 433 MHz receiver" << std::endl;
            std::cout << "  --no-audio       skip audio init (decode and act, play nothing)\n"
                         "  --simulate       read RF codes from stdin instead of GPIO15\n";
            std::cout << "  --version, -v    print version" << std::endl;
            std::cout << "Dvě koule: zelená plynule prolíná " << N_MOOD
                      << " náladové stopy Interactive_* (crossfade), červená "
                      << "kvadrantem přepíná " << N_INTER
                      << " intermezza Inter_* (I4 je podklad track9) on/off. "
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
        if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
            camDevice = argv[i + 1];
            i++;
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
        if (strcmp(argv[i], "--max-area") == 0 && i + 1 < argc) {
            ballMaxArea = std::atoi(argv[++i]);
            if (ballMaxArea < 0) ballMaxArea = 0;
        }
        if (strcmp(argv[i], "--min-roundness") == 0 && i + 1 < argc) {
            ballMinRoundness = (float)std::atof(argv[++i]);
            if (ballMinRoundness < 0) ballMinRoundness = 0;
            if (ballMinRoundness > 1) ballMinRoundness = 1;
        }
        if (strcmp(argv[i], "--gate-px") == 0 && i + 1 < argc) {
            ballGatePx = (float)std::atof(argv[++i]);
            if (ballGatePx < 0) ballGatePx = 0;
        }
        if (strcmp(argv[i], "--adapt-alpha") == 0 && i + 1 < argc) {
            ballAdaptAlpha = (float)std::atof(argv[++i]);
            if (ballAdaptAlpha < 0) ballAdaptAlpha = 0;
            if (ballAdaptAlpha > 0.5f) ballAdaptAlpha = 0.5f;
        }
        if (strcmp(argv[i], "--reacquire-px") == 0 && i + 1 < argc) {
            ballReacquirePx = (float)std::atof(argv[++i]);
            if (ballReacquirePx < 0) ballReacquirePx = 0;
        }
        if (strcmp(argv[i], "--bg") == 0 && i + 1 < argc) {
            bgFile = argv[++i];
        }
        if (strcmp(argv[i], "--bg-diff") == 0 && i + 1 < argc) {
            bgDiffThresh = std::atoi(argv[++i]);
            if (bgDiffThresh < 1) bgDiffThresh = 1;
        }
        if (strcmp(argv[i], "--no-bg") == 0) {
            bgEnabled = false;
        }
        if (strcmp(argv[i], "--lock-exposure") == 0) {
            lockExposure = true;
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
    int frameWidth = 0, frameHeight = 0;
    bool camReady = false;
    bool camOpen = false;              // V4L2 zařízení otevřeno
    const unsigned char* rgbPtr = nullptr;
    Font font = {0};
    float scale = 1.0f;
    float offX = 0.0f, offY = 0.0f;
    Image raylibImage = {0};
    Texture2D videoTex = {0};
    struct v4l2_frame camFrame = {0};

    auto openCamera = [&]() -> bool {
        if (!camOpen) {
            // MJPG dovolí 1280x720 (i vyšší) po USB2; když to kamera neumí,
            // v4l2_open sám spadne na YUYV (nižší rozlišení).
            if (v4l2_open(camDevice, reqWidth, reqHeight, 1) != 0) return false;
            camOpen = true;
            if (lockExposure) {
                // Automatická expozice/WB mění barvy za běhu a koule pak
                // "mizí"; napevno je držíme. Hodnoty zůstávají na kameře.
                v4l2_lock_exposure(1);
                std::cerr << "camera: auto-exposure/WB off (--lock-exposure)"
                          << std::endl;
            }
        }
        if (v4l2_grab(&camFrame, 2000) != 0 || !camFrame.rgb) return false;
        frameWidth = camFrame.w;
        frameHeight = camFrame.h;
        rgbPtr = camFrame.rgb;
        loadCalib(frameWidth, frameHeight);
        if (bgEnabled && !bgRefOn && !bgWarned) {
            if (!loadBgRef(bgFile, frameWidth, frameHeight)) {
                std::cerr << "bg: reference " << bgFile
                          << " nenalezena — detekce bez odstranění pozadí "
                             "(v okně stiskni B na prázdné ploše)" << std::endl;
                bgWarned = true;
            }
        }
        raylibImage = Image{const_cast<unsigned char*>(rgbPtr), frameWidth,
                            frameHeight, 1, PIXELFORMAT_UNCOMPRESSED_R8G8B8};
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
              << "green " << N_MOOD << " mood crossfade + red " << N_INTER
              << " inter switch, "
              << mixCh << " loop (interaction off until F) + "
              << BUTTONS_MAX_SLOTS << " button channel(s), "
              << buttons.slotCount() << " RF slot(s), "
              << reqWidth << "x" << reqHeight << " capture, "
              << (detectMs > 0 ? std::to_string(1000 / std::max(1, detectMs)) + "Hz detect"
                               : std::string("detect every frame"))
              << std::endl;

    bool dragging = false;
    int dragIdx = -1;

    // Homografie i maska podlahy závisí jen na rozích kalibrace, takže se
    // přepočítají jen když je kalibrace "špinavá" — ne na každém snímku.
    Mat3 H, Hinv;
    bool calibDirty = true;

    Ball red, green;            // green = 4 náladové stopy, red = 4 intermezza

    // Kameru zkoušíme otevřít nejvýš každé 2 s — otevření V4L2 zařízení
    // blokuje a bez throttlingu by pokusy zaplavily CPU i journal.
    auto lastCamTry = std::chrono::steady_clock::now() - std::chrono::seconds(10);
    bool camWarned = false;
    // Detekci (nejdražší část) pouštíme nejvýš každých detectMs milisekund.
    auto lastDetect = std::chrono::steady_clock::now() - std::chrono::hours(1);
    // Čas minulého snímku pro Kalman (predikce mezi detekcemi).
    auto lastLoop = std::chrono::steady_clock::now();
    // Sběr snímků pro referenci pozadí (klávesa B): průměr BG_FRAMES snímků.
    int bgCaptureLeft = 0;
    std::vector<unsigned long> bgAccum;   // w*h*3 součtů (unsigned long)

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

        if (v4l2_grab(&camFrame, 2000) != 0 || !camFrame.rgb) {
            std::cerr << "camera: frame timeout, reconnecting" << std::endl;
            v4l2_close();
            camOpen = false;
            camReady = false;
            continue;
        }
        rgbPtr = camFrame.rgb;
        raylibImage.data = const_cast<unsigned char*>(rgbPtr);

        if (calibDirty) {
            Pt src[4] = {corners[0], corners[1], corners[2], corners[3]};
            Pt dst[4] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};
            H = homography4(src, dst);
            Hinv = invert3(H);
            buildFloorMask(frameWidth, frameHeight);
            calibDirty = false;
        }

        // ── sběr reference pozadí (klávesa B) ──────────────────────────────
        // Průměr BG_FRAMES snímků prázdné plochy (koule mimo stůl); průměr
        // potlačí šum senzoru. Běží jen v okenním režimu (klávesa B).
        if (bgCaptureLeft > 0) {
            size_t N = (size_t)frameWidth * frameHeight * 3;
            if (bgAccum.size() != N) bgAccum.assign(N, 0);
            for (size_t p = 0; p < N; p++) bgAccum[p] += rgbPtr[p];
            if (--bgCaptureLeft == 0) {
                std::vector<unsigned char> avg(N);
                for (size_t p = 0; p < N; p++) avg[p] = (unsigned char)(bgAccum[p] / BG_FRAMES);
                if (saveBgRef(bgFile, avg.data(), frameWidth, frameHeight))
                    std::cerr << "bg: reference uložena (" << bgFile << ")" << std::endl;
                loadBgRef(bgFile, frameWidth, frameHeight);
            }
        }

        // ── predikce polohy (Kalman) ───────────────────────────────────────
        // Predikujeme každý snímek (i mezi detekcemi), aby koule plynule
        // pokračovala a nezavlékala; dt je skutečný čas od minulého snímku.
        auto loopNow = std::chrono::steady_clock::now();
        float dt = std::chrono::duration<float>(loopNow - lastLoop).count();
        lastLoop = loopNow;
        if (dt < 0.0f) dt = 0.0f;
        if (dt > 0.5f) dt = 0.5f;
        red.predict(dt);
        green.predict(dt);

        // ── koule (barevný blob) ───────────────────────────────────────────
        // Zamčená koule se hledá jen v úzkém okně kolem predikce (méně pixelů
        // = rychlejší a stabilnější), ztracená v celé ploše (re-acquire).
        // Navíc jen každých detectMs ms (koule se hýbou pomalu).
        auto detNow = std::chrono::steady_clock::now();
        bool doDetect = detectMs <= 0 ||
            std::chrono::duration_cast<std::chrono::milliseconds>(detNow - lastDetect).count() >= detectMs;
        if (doDetect) {
            lastDetect = detNow;
            // Maska rozdílu od prázdné plochy (jedna pro obě koule). Bez
            // reference je nullptr a detekce jede jen barevně + podle plochy.
            const unsigned char* fgMask = bgRefOn
                ? buildFgMask(rgbPtr, frameWidth, frameHeight, bgDiffThresh)
                : nullptr;
            auto detectOne = [&](int color, Ball& b, const Ball& other) {
                Box roi;
                if (b.present && b.kx.init) {
                    float margin = std::max(90.0f,
                        0.75f * std::max((float)b.bbox.w, (float)b.bbox.h) + 60.0f);
                    int x0 = std::max((int)(b.sx - margin), floorROI.x);
                    int y0 = std::max((int)(b.sy - margin), floorROI.y);
                    int x1 = std::min((int)(b.sx + margin), floorROI.x + floorROI.w);
                    int y1 = std::min((int)(b.sy + margin), floorROI.y + floorROI.h);
                    roi = Box{x0, y0, std::max(0, x1 - x0), std::max(0, y1 - y0)};
                } else {
                    roi = floorROI;
                }
                if (roi.w < 8 || roi.h < 8) roi = floorROI;
                Pt c; Box bx; float mS = 0, mV = 0;
                Pt prev = (b.present && b.kx.init) ? Pt{b.sx, b.sy} : Pt{-1, -1};
                Pt avoid = (other.present && other.kx.init)
                    ? Pt{other.sx, other.sy} : Pt{-1, -1};
                // Zamčená koule: jen blob do gate okruhu od predikce (a blíž
                // k nám než k druhé kouli). Ztracená: největší blob kdekoliv.
                float gate = std::max(60.0f, 0.5f * std::min((float)roi.w, (float)roi.h));
                bool found = detectBall(rgbPtr, frameWidth, frameHeight,
                                        floorMaskFull.data(), fgMask, color, roi,
                                        prev, gate, ballReacquirePx, avoid,
                                        c, bx, &mS, &mV);
                if (found) {
                    b.correct(c.x, c.y, bx);
                    // Adaptace saturace/jasu naučené barvy (pomalu, proti
                    // driftu expozice; odstín zůstává naučený).
                    ColorModel& cm = ballColor[color];
                    if (cm.set && mS > 0 && mV > 0) {
                        cm.s = (int)std::lround(cm.s + (mS - cm.s) * ballAdaptAlpha);
                        cm.v = (int)std::lround(cm.v + (mV - cm.v) * ballAdaptAlpha);
                        if (cm.s < 1) cm.s = 1;
                        if (cm.v < 1) cm.v = 1;
                    }
                } else {
                    b.miss();
                }
            };
            detectOne(BALL_RED, red, green);
            detectOne(BALL_GREEN, green, red);
        }

        // ── hlasitost: smyčky hrají jen když je interaction zapnutá ────────
        // Vypnutá interaction = ticho (F ztlumí všechny smyčky); zapnutá
        // interaction míchá 4 nálady + 4 intermezza podle koulí.
        if (!interactive) {
            for (int ch = 0; ch < N_LOOP; ch++)
                if (Mix_Volume(ch, -1) != 0) Mix_Volume(ch, 0);
        } else {
        // ── hlasitost: zelená koule plynule prolíná 4 náladové stopy ────────
        // Náladové stopy (T1-T4 = Interactive_*) se míchají 2D crossfadem:
        // rektifikovaná X/Y dává lineární váhu oběma osám, takže se mezi
        // kvadranty plynule prolíná (uprostřed znějí všechny čtyři).
        //   T1 (WAR) = nahoře, T2 (PEACE) = dole, T3 (DRAMA) = vlevo,
        //   T4 (INTIMACY) = vpravo. Bez koule = všechny ztlumené.
        float tgt[N_MOOD] = {0, 0, 0, 0};
        if (green.present) {
            float u, v;
            rectify(H, green.sx, green.sy, u, v);
            tgt[0] = 1.0f - v;   // Y nahoře -> T1 (WAR)
            tgt[1] = v;          // Y dole   -> T2 (PEACE)
            tgt[2] = 1.0f - u;   // X vlevo  -> T3 (DRAMA)
            tgt[3] = u;          // X vpravo -> T4 (INTIMACY)
        }
        for (int ch = 0; ch < N_MOOD; ch++) {
            if (tgt[ch] > 1.0f) tgt[ch] = 1.0f;
            int target = (int)(tgt[ch] * 128.0f * LOOP_MOOD_VOLUME);
            int cur = Mix_Volume(ch, -1);
            int next = (int)(cur + (float)(target - cur) * VOL_SMOOTH_ALPHA);
            if (target == 0 && cur < 2) next = 0;   // bez šumu v tichu
            if (next > 128) next = 128;
            if (next < 0) next = 0;
            Mix_Volume(ch, next);
        }

        // ── hlasitost: červená koule tvrdě přepíná 4 intermezza on/off ──────
        // Intermezza (I1-I4 = Inter_* + podklad track9) hrají vždy nejvýš
        // jedna: kvadrant, ve kterém je červená koule, danou stopu zapne a
        // ostatní vypne (žádný crossfade — je to switch). Stejné pořadí jako
        // u T: I1 nahoře, I2 dole, I3 vlevo, I4 vpravo. Bez koule jsou všechny
        // vypnuté.
        int interOn = -1;
        if (red.present) {
            float u, v;
            rectify(H, red.sx, red.sy, u, v);
            float du = u - 0.5f, dv = v - 0.5f;
            if (fabsf(dv) >= fabsf(du)) interOn = (dv < 0.0f) ? 0 : 1;
            else                        interOn = (du < 0.0f) ? 2 : 3;
        }
        for (int ch = 0; ch < N_INTER; ch++)
            Mix_Volume(N_MOOD + ch, ch == interOn ? 128 : 0);
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
            if (IsKeyPressed(KEY_B)) {
                // Změř referenci pozadí z aktuální prázdné plochy (koule mimo
                // stůl). Uloží se do bgFile a hned se použije.
                bgCaptureLeft = BG_FRAMES;
                bgAccum.clear();
                std::cerr << "bg: měřím prázdnou plochu (" << BG_FRAMES
                          << " snímků; drž koule mimo stůl)…" << std::endl;
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
                Pt mp{mx, my};
                // Pravé tlačítko: nauč barvu červené (inter) koule.
                if (IsMouseButtonPressed(MOUSE_BUTTON_RIGHT)) {
                    teachColor(rgbPtr, frameWidth, frameHeight, BALL_RED, mp);
                    saveCalib();
                }
                if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT)) {
                    // Na rohu kalibrace se táhne; jinde klik naučí zelenou kouli.
                    dragIdx = nearestCorner(mp);
                    if (dragIdx >= 0) dragging = true;
                    else {
                        teachColor(rgbPtr, frameWidth, frameHeight, BALL_GREEN, mp);
                        saveCalib();
                    }
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
            raylibImage.data = const_cast<unsigned char*>(rgbPtr);

            // Texturu vytvoříme jednou a dál do ní jen nahráváme pixely.
            // LoadTextureFromImage každý snímek by znovu alokoval GPU texturu.
            if (videoTex.id == 0) videoTex = LoadTextureFromImage(raylibImage);
            else UpdateTexture(videoTex, rgbPtr);

            BeginDrawing();
            ClearBackground(BLACK);
            rlPushMatrix();
            rlTranslatef(offX, offY, 0.0f);
            rlScalef(scale, scale, 1.0f);
            DrawTexture(videoTex, 0, 0, WHITE);
            drawGrid(Hinv);

            for (int i = 0; i < 4; i++) {
                Color c = (i < 2) ? (Color){255, 80, 80, 255} : (Color){80, 80, 255, 255};
                DrawCircle((int)corners[i].x, (int)corners[i].y, 8, c);
            }

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
                                (float)red.bbox.w, (float)red.bbox.h},
                    3.0f, rDraw);
                DrawTextEx(font, "R", {(float)red.bbox.x, (float)red.bbox.y - 20},
                           18, 0.0f, rDraw);
            } else {
                DrawTextEx(font, "R lost", {20, 60}, 18, 0.0f, rDraw);
            }
            if (green.present) {
                DrawRectangleLinesEx(
                    (Rectangle){(float)green.bbox.x, (float)green.bbox.y,
                                (float)green.bbox.w, (float)green.bbox.h},
                    3.0f, gDraw);
                DrawTextEx(font, "G", {(float)green.bbox.x, (float)green.bbox.y - 20},
                           18, 0.0f, gDraw);
            } else {
                DrawTextEx(font, "G lost", {20, 90}, 18, 0.0f, gDraw);
            }

            // Debug: predikovaný střed (křížek) a gate pro obě koule.
            auto drawMark = [&](const Ball& b, Color col) {
                if (!b.present || !b.kx.init) return;
                int x = (int)b.sx, y = (int)b.sy;
                DrawLine(x - 8, y, x + 8, y, col);
                DrawLine(x, y - 8, x, y + 8, col);
                if (ballGatePx > 0) DrawCircleLines(x, y, (int)ballGatePx, col);
            };
            drawMark(red, rDraw);
            drawMark(green, gDraw);

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
                Color c = (i < N_MOOD) ? GREEN : RED;
                DrawRectangle(bx, barY, bw, barH, (Color){c.r, c.g, c.b, 40});
                DrawRectangle(bx, barY + barH - (int)(fill * barH), bw, (int)(fill * barH), c);
                DrawRectangleLines(bx, barY, bw, barH, WHITE);
                const char* lbl = (i < N_MOOD) ? TextFormat("T%d", i + 1)
                                               : TextFormat("I%d", i - N_MOOD + 1);
                DrawTextEx(font, lbl, {(float)(bx + 4), (float)(barY + 2)}, 14, 0.0f, WHITE);
            }

            Color iCol = interactive ? GREEN : GRAY;
            DrawTextEx(font, TextFormat("interaction: %s", interactive ? "ON" : "OFF"),
                {(float)(frameWidth - 200), (float)(frameHeight - 108)}, 18, 0.0f, iCol);

            DrawTextEx(font, "F = interaction on/off | [ ] sens | S save | R reset | C clear",
                {10, 10}, 16, 0.0f, RAYWHITE);
            DrawTextEx(font, "left-click=teach G  right-click=teach R",
                {10, 30}, 16, 0.0f, RAYWHITE);
            DrawTextEx(font, "green=T1-T4 crossfade  red=I1-I4 switch (I4=track9)",
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
    v4l2_close();
    return 0;
}
