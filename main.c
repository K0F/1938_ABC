#ifndef GIT_VERSION
#define GIT_VERSION "dev"
#endif
#define VERSION_STRING GIT_VERSION

#include <opencv2/opencv.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/calib3d.hpp>
#ifdef GRAY
#undef GRAY
#endif
#include <opencv2/tracking.hpp>
#include <opencv2/video.hpp>
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
#include <csignal>

#define CALIB_FILE "calib.txt"
#define MAX_PEOPLE 16
#define DEFAULT_MAX_PEOPLE 8
#define HANDLE_RADIUS 20.0f
#define GRID_DIV 8
#define PERSON_MIN_AREA 800
#define PERSON_MAX_AREA_FRAC 0.60f
#define PERSON_MIN_SOLIDITY 0.12f
#define WARMUP_FRAMES 30
#define DETECT_INTERVAL 12
#define LOST_FRAMES 5
#define STALE_TTL 120
#define VOL_SMOOTH_ALPHA 0.30f
#define MATCH_MARGIN 0.55f

static volatile sig_atomic_t g_quit = 0;

static void onSignal(int) { g_quit = 1; }

static cv::Point2f corners[4];

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
        f.close();
    }
}

static void loadCalib(int w, int h) {
    corners[0] = cv::Point2f(0, 0);
    corners[1] = cv::Point2f(w, 0);
    corners[2] = cv::Point2f(0, h);
    corners[3] = cv::Point2f(w, h);
    std::ifstream f(CALIB_FILE);
    if (f) {
        for (int i = 0; i < 4; i++) f >> corners[i].x >> corners[i].y;
        f.close();
    }
}

// Maska hrací plochy = polygon z kalibrovaných rohů. Mimo něj pohyb nehraje.
static void buildFloorMask(int w, int h, cv::Mat& mask) {
    mask = cv::Mat::zeros(h, w, CV_8UC1);
    std::vector<cv::Point> pts;
    for (int i = 0; i < 4; i++) pts.push_back(cv::Point((int)corners[i].x, (int)corners[i].y));
    cv::fillPoly(mask, std::vector<std::vector<cv::Point>>{pts}, cv::Scalar(255));
}

struct Person {
    bool tracking = true;      // live (CSRT běží) vs. stale (čeká na re-acquire)
    int lost = 0;              // po sobě jdoucí neúspěšné update()
    int stale = 0;             // kolik detekčních cyklů je stale
    cv::Rect bbox;             // aktuální / poslední známá pozice
    cv::Rect lastBbox;
    cv::Ptr<cv::TrackerCSRT> tracker;
};

static bool sameRegion(const cv::Rect& a, const cv::Rect& b, float margin) {
    float cax = (float)a.x + (float)a.width / 2.0f;
    float cay = (float)a.y + (float)a.height / 2.0f;
    float cbx = (float)b.x + (float)b.width / 2.0f;
    float cby = (float)b.y + (float)b.height / 2.0f;
    float sx = (float)(a.width + b.width) / 2.0f;
    float sy = (float)(a.height + b.height) / 2.0f;
    return std::abs(cax - cbx) < sx * margin && std::abs(cay - cby) < sy * margin;
}

// Detekce pohybu (bloby z MOG2) v už rozmorfovaném fgmasku -> kandidáti lidé.
static void detectPeople(const cv::Mat& frame, const cv::Mat& fgmask, std::vector<cv::Rect>& dets) {
    cv::Mat fg;
    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, {9, 9});
    cv::morphologyEx(fgmask, fg, cv::MORPH_OPEN, kernel);
    cv::morphologyEx(fg, fg, cv::MORPH_CLOSE, kernel);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(fg, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    int maxArea = (int)(frame.cols * frame.rows * PERSON_MAX_AREA_FRAC);
    for (auto& c : contours) {
        double a = cv::contourArea(c);
        if (a < PERSON_MIN_AREA || a > maxArea) continue;
        cv::Rect r = cv::boundingRect(c);
        // Obrys musí být slušně vyplněný — světelný záblesk/ring má bbox přes
        // půl scany, ale minimum výplně. Lidé zhora jsou plné bloby.
        if (r.empty() || (double)(r.width * r.height) <= 0) continue;
        double solidity = a / (double)(r.width * r.height);
        if (solidity < PERSON_MIN_SOLIDITY) continue;
        dets.push_back(r);
    }
}

int main(int argc, char* argv[]) {
    bool headless = false;
    int maxPeople = DEFAULT_MAX_PEOPLE;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-v") == 0) {
            std::cout << "tracker " << VERSION_STRING << std::endl;
            return 0;
        }
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            std::cout << "tracker " << VERSION_STRING << std::endl;
            std::cout << "usage: tracker [options] [max-people 1-" << MAX_PEOPLE << "]" << std::endl;
            std::cout << "  --headless, -H   run without a window (systemd / Box A)" << std::endl;
            std::cout << "  --max-people N   max concurrently tracked people (default "
                      << DEFAULT_MAX_PEOPLE << ")" << std::endl;
            std::cout << "  --version, -v    print version" << std::endl;
            return 0;
        }
        if (strcmp(argv[i], "--headless") == 0 || strcmp(argv[i], "-H") == 0) {
            headless = true;
        }
        if (strcmp(argv[i], "--max-people") == 0 && i + 1 < argc) {
            int n = std::atoi(argv[i + 1]);
            if (n >= 1 && n <= MAX_PEOPLE) { maxPeople = n; i++; }
        }
    }
    // Bývalý počet míčků = nyní maximální počet lidí (zpětná kompatibilita CLI).
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') continue;
        int n = std::atoi(argv[i]);
        if (n >= 1 && n <= MAX_PEOPLE) { maxPeople = n; break; }
    }

    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);

    cv::VideoCapture cap(0);
    if (!cap.isOpened()) {
        std::cerr << "Error: Could not open video capture device." << std::endl;
        return -1;
    }

    cv::Mat frame;
    cap >> frame;
    if (frame.empty()) {
        std::cerr << "Error: Captured empty frame." << std::endl;
        return -1;
    }

    int frameWidth = frame.cols;
    int frameHeight = frame.rows;

    Font font = {0};
    float scale = 1.0f;   // 1.0 = okno 1:1 s kamerou (Xvfb, vývoj)
    float offX = 0.0f, offY = 0.0f;  // horní levý roh obrazu v okně
    if (!headless) {
        // Vývoj (Xvfb, jiný display): okno 1:1 s kamerou
        InitWindow(frameWidth, frameHeight, "Tracker " VERSION_STRING);
        SetTargetFPS(60);

        // Na HDMI konzoli má být obraz na celé TV, takže okno natáhnu na celý
        // monitor. Rozměry monitoru se dají zjistit až po otevření okna —
        // v raylib je totiž GetScreenWidth() šířka OKNA (framebufferu), ne
        // monitoru, a na začátku bych si přepsal sám sebe.
        // NE přes FLAG_FULLSCREEN_MODE: ten si vybere "nejbližší video režim"
        // k velikosti okna, tedy 640x480, a na Raspberry Pi přepne výstup —
        // tam GLX vizuály nejsou a okno vůbec nevznikne. Bez window managera
        // okno prostě leží přes celou obrazovku.
        int mon = GetCurrentMonitor();
        if (mon >= 0) {
            int monW = GetMonitorWidth(mon);
            int monH = GetMonitorHeight(mon);
            if (monW > 0 && monH > 0
                && (monW != frameWidth || monH != frameHeight)) {
                SetWindowSize(monW, monH);
                // Bez window managera se okno po zvětšení neposune samo a
                // zůstane vycentrované podle původní velikosti — na TV by pak
                // visela jen jeho pravá polovina.
                SetWindowPosition(0, 0);
            }
        }
        int outW = GetScreenWidth();
        int outH = GetScreenHeight();
        // 4:3 snímek na 16:9 monitor natáhnout na plnou šířku by zkreslilo
        // lidi na hady, takže se vejde svisle a do stran zbude pillarbox.
        if (outW > 0 && outH > 0) {
            scale = (float)outW / (float)frameWidth;
            if ((float)outH / (float)frameHeight < scale) {
                scale = (float)outH / (float)frameHeight;
            }
            offX = ((float)outW - frameWidth * scale) / 2.0f;
            offY = ((float)outH - frameHeight * scale) / 2.0f;
            // na stderr, ne na stdout: stdout jde v konzoli do souboru, a to je
            // blokově bufferované — řádek by se objevil až při konci procesu,
            // když je už k poštování pozdě.
            std::cerr << "  okno " << outW << "x" << outH
                      << ", snímek " << frameWidth << "x" << frameHeight
                      << " x" << scale << " na (" << (int)offX << "," << (int)offY << ")" << std::endl;
        }

        font = LoadFontEx("terminus.ttf", 20, NULL, 0);
        if (font.texture.id <= 0) font = GetFontDefault();
        else SetTextureFilter(font.texture, TEXTURE_FILTER_POINT);
    }

    SDL_Init(SDL_INIT_AUDIO);
    if (Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 1024) != 0) {
        // Bez zvukové karty raději nepuštit dál — otevřený PCM by stejně zemřel.
        // Exit -> Restart=always v tracker.service to zkusí znovu, až karta dorazí.
        std::cerr << "Error: audio open failed: " << Mix_GetError() << std::endl;
        return -1;
    }
    int mixCh = 4;                              // 4 nálady, součet přes všechny lidi
    Mix_AllocateChannels(mixCh);

    Mix_Chunk* tracks[8] = {0};
    for (int i = 0; i < mixCh; i++) {
        tracks[i] = Mix_LoadWAV(TextFormat("samples/track%d.wav", i + 1));
        if (tracks[i]) Mix_PlayChannel(i, tracks[i], -1);
    }
    for (int i = 0; i < mixCh; i++) Mix_Volume(i, 0);

    loadCalib(frameWidth, frameHeight);

    {
        // Spec, který SDL2_mixer opravdu otevřelo, a přes který driver. Který
        // to je zařízení, ví box-alsa-setup.sh (pcm.!default) a box-audio-test.sh
        // — SDL2 jméno otevřeného zařízení neposkytuje.
        int freq = 0, chans = 0;
        Uint16 fmt = 0;
        Mix_QuerySpec(&freq, &fmt, &chans);

        const char* drv = SDL_GetCurrentAudioDriver();
        std::cerr << "audio: " << (drv ? drv : "?") << " " << freq << " Hz, "
                  << chans << " channel(s)" << std::endl;
    }

    std::cerr << "tracker " VERSION_STRING << " start: "
              << (headless ? "headless" : "window") << ", "
              << frameWidth << "x" << frameHeight << ", "
              << "people, max " << maxPeople << ", " << mixCh << " audio channel(s)"
              << std::endl;

    cv::Ptr<cv::BackgroundSubtractor> bg = cv::createBackgroundSubtractorMOG2(500, 16, false);
    cv::Mat fgmask;
    std::vector<Person> people;
    std::vector<cv::Rect> dets;
    unsigned long frameNo = 0;

    Image raylibImage = {
        .data = frame.data,
        .width = frameWidth,
        .height = frameHeight,
        .mipmaps = 1,
        .format = PIXELFORMAT_UNCOMPRESSED_R8G8B8
    };

    cv::Mat rgbFrame;
    bool dragging = false;
    int dragIdx = -1;

    while (headless ? !g_quit : (!WindowShouldClose() && !g_quit)) {
        cap >> frame;
        if (frame.empty()) break;
        frameNo++;

        cv::Point2f src[4] = {corners[0], corners[1], corners[2], corners[3]};
        cv::Point2f dst[4] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};
        cv::Mat H = cv::getPerspectiveTransform(src, dst);
        cv::Mat Hinv = H.inv();

        // ── aktualizace trackerů (každý snímek) ────────────────────────────
        for (auto& p : people) {
            if (!p.tracking) continue;          // stale nesledujeme, jen hledáme
            bool ok = p.tracker->update(frame, p.bbox);
            if (ok) {
                cv::Rect fr(0, 0, frameWidth, frameHeight);
                p.bbox &= fr;
                if (!p.bbox.empty()) {
                    p.lost = 0;
                    p.lastBbox = p.bbox;
                } else {
                    ok = false;
                }
            }
            if (!ok) {
                p.lost++;
                if (p.lost >= LOST_FRAMES) {
                    p.tracking = false;         // ztracen -> čeká na re-acquire
                    p.stale = 0;
                    std::cerr << "people -: P" << (&p - &people[0]) + 1
                              << " (lost at " << p.lastBbox.x << "," << p.lastBbox.y << ")"
                              << std::endl;
                }
            }
        }

        // ── detekce nových lidí (každých DETECT_INTERVAL snímků) ──────────
        // MOG2 model se krmí každým snímkem; prvních WARMUP_FRAMES nehlásíme,
        // aby počáteční záběr celé scény nebyl brán jako člověk.
        bg->apply(frame, fgmask, -1);
        if (frameNo % DETECT_INTERVAL == 0 && frameNo >= WARMUP_FRAMES) {
            cv::Mat floorMask;
            buildFloorMask(frameWidth, frameHeight, floorMask);
            cv::Mat masked;
            cv::bitwise_and(fgmask, floorMask, masked);
            dets.clear();
            detectPeople(frame, masked, dets);

            for (auto& d : dets) {
                bool claimed = false;
                // Už sledovaný živý člověk — detekce nad ním, nic nezakládám.
                for (auto& p : people) {
                    if (p.tracking && sameRegion(p.bbox, d, MATCH_MARGIN)) {
                        claimed = true;
                        break;
                    }
                }
                if (claimed) continue;

                // Re-acquire ztraceného člověka poblíž detekce.
                for (size_t pi = 0; pi < people.size(); pi++) {
                    Person& p = people[pi];
                    if (!p.tracking && sameRegion(p.lastBbox, d, MATCH_MARGIN * 1.5f)) {
                        p.bbox = d;
                        p.lastBbox = d;
                        p.tracker = cv::TrackerCSRT::create();
                        p.tracker->init(frame, p.bbox);
                        p.tracking = true;
                        p.lost = 0;
                        p.stale = 0;
                        std::cerr << "people re-acq: P" << pi + 1
                                  << " @" << d.x << "," << d.y
                                  << " " << d.width << "x" << d.height
                                  << std::endl;
                        claimed = true;
                        break;
                    }
                }
                if (claimed) continue;

                // Nový člověk.
                if ((int)people.size() < maxPeople) {
                    Person p;
                    p.bbox = d;
                    p.lastBbox = d;
                    p.tracker = cv::TrackerCSRT::create();
                    p.tracker->init(frame, p.bbox);
                    p.tracking = true;
                    people.push_back(p);
                    std::cerr << "people +: P" << people.size()
                              << " @" << d.x << "," << d.y
                              << " " << d.width << "x" << d.height
                              << std::endl;
                }
            }

            // Stale lidé bez návratu přes odpočet vyhodit.
            for (auto it = people.begin(); it != people.end(); ) {
                if (!it->tracking) {
                    if (it->stale >= STALE_TTL) {
                        std::cerr << "people -: P" << (std::distance(people.begin(), it)) + 1
                                  << " (gone)" << std::endl;
                        it = people.erase(it);
                        continue;
                    }
                    it->stale++;
                }
                ++it;
            }
        }

        // ── hlasitost: součet všech lidí do 4 stop, clamp + vyhlazení ──────
        float tgt[4] = {0, 0, 0, 0};
        for (auto& p : people) {
            if (!p.tracking || p.lost > 0) continue;
            float cx = (float)p.bbox.x + (float)p.bbox.width / 2.0f;
            float cy = (float)p.bbox.y + (float)p.bbox.height / 2.0f;
            cv::Point2f pt(cx, cy);
            std::vector<cv::Point2f> srcPts = {pt};
            std::vector<cv::Point2f> dstPts;
            cv::perspectiveTransform(srcPts, dstPts, H);
            double u = dstPts[0].x;
            double v = dstPts[0].y;
            if (u < 0) u = 0; if (u > 1) u = 1;
            if (v < 0) v = 0; if (v > 1) v = 1;
            tgt[0] += (float)(1.0 - v);   // Y nahoře
            tgt[1] += (float)v;           // Y dole
            tgt[2] += (float)(1.0 - u);   // X vlevo
            tgt[3] += (float)u;           // X vpravo
        }
        for (int ch = 0; ch < mixCh; ch++) {
            if (tgt[ch] > 1.0f) tgt[ch] = 1.0f;
            int target = (int)(tgt[ch] * 128.0f);
            int cur = Mix_Volume(ch, -1);
            int next = (int)(cur + (float)(target - cur) * VOL_SMOOTH_ALPHA);
            if (target == 0 && cur < 2) next = 0;   // bez šumu v tichu
            if (next > 128) next = 128;
            if (next < 0) next = 0;
            Mix_Volume(ch, next);
        }

        if (!headless) {
            if (IsKeyPressed(KEY_S)) saveCalib();
            if (IsKeyPressed(KEY_R)) loadCalib(frameWidth, frameHeight);

            // Myš je v souřadnicích okna, kalibrace v souřadnicích snímku.
            Vector2 mouse = GetMousePosition();
            float mx = ((float)mouse.x - offX) / scale;
            float my = ((float)mouse.y - offY) / scale;
            if (mx >= 0 && my >= 0 && mx < frameWidth && my < frameHeight) {
                cv::Point2f mp(mx, my);
                if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT)) {
                    dragIdx = nearestCorner(mp);
                    dragging = dragIdx >= 0;
                } else if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) {
                    dragging = false;
                }
                if (dragging && dragIdx >= 0) corners[dragIdx] = mp;
            } else {
                dragging = false;
            }
        }

        if (!headless) {
            cv::cvtColor(frame, rgbFrame, cv::COLOR_BGR2RGB);
            gridLines(rgbFrame, Hinv);
            raylibImage.data = rgbFrame.data;

            Texture2D texture = LoadTextureFromImage(raylibImage);

            BeginDrawing();
            ClearBackground(BLACK);
            rlPushMatrix();
            rlTranslatef(offX, offY, 0.0f);
            rlScalef(scale, scale, 1.0f);
            DrawTexture(texture, 0, 0, WHITE);

            for (int i = 0; i < 4; i++) {
                Color c = (i < 2) ? (Color){255, 80, 80, 255} : (Color){80, 80, 255, 255};
                DrawCircle((int)corners[i].x, (int)corners[i].y, 8, c);
            }

            for (size_t i = 0; i < people.size(); i++) {
                Color c = (i % 2 == 0) ? RED : GREEN;
                bool live = people[i].tracking && people[i].lost <= 0;
                if (live) {
                    DrawRectangleLinesEx(
                        (Rectangle){(float)people[i].bbox.x, (float)people[i].bbox.y,
                                    (float)people[i].bbox.width, (float)people[i].bbox.height},
                        3.0f, c
                    );
                    DrawTextEx(font, TextFormat("P%zu", i + 1),
                        {(float)people[i].bbox.x, (float)people[i].bbox.y - 20}, 18, 0.0f, c);
                } else {
                    DrawTextEx(font, TextFormat("P%zu Lost", i + 1),
                        {20, 20 + (float)i * 30.0f}, 18, 0.0f, c);
                }
            }

            int barH = 60;
            int barW = frameWidth / mixCh;
            int barY = frameHeight - barH - 10;
            for (int i = 0; i < mixCh; i++) {
                int vol = Mix_Volume(i, -1);
                float fill = (float)vol / 128.0f;
                int bx = i * barW + 5;
                int bw = barW - 10;
                Color c = (i % 2 == 0) ? RED : BLUE;
                DrawRectangle(bx, barY, bw, barH, (Color){c.r, c.g, c.b, 40});
                DrawRectangle(bx, barY + barH - (int)(fill * barH), bw, (int)(fill * barH), c);
                DrawRectangleLines(bx, barY, bw, barH, WHITE);
                DrawTextEx(font, TextFormat("T%d", i + 1),
                    {(float)(bx + 4), (float)(barY + 2)}, 14, 0.0f, WHITE);
            }

            DrawTextEx(font, "Drag corners | S save | R reset",
                {10, 10}, 16, 0.0f, RAYWHITE);
            DrawTextEx(font, TextFormat("People: %zu/%d", people.size(), maxPeople),
                {10, (float)(frameHeight - 80)}, 16, 0.0f, RAYWHITE);

            rlPopMatrix();
            EndDrawing();
            UnloadTexture(texture);
        }
    }

    std::cerr << "tracker " VERSION_STRING << " stop" << std::endl;
    if (!headless) {
        UnloadFont(font);
        CloseWindow();
    }
    for (int i = 0; i < 8; i++) if (tracks[i]) Mix_FreeChunk(tracks[i]);
    Mix_CloseAudio();
    SDL_Quit();
    cap.release();
    return 0;
}