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
#include "raylib.h"
#include <SDL2/SDL.h>
#include <SDL2/SDL_mixer.h>
#include <iostream>
#include <vector>
#include <fstream>
#include <string>
#include <cstdlib>
#include <cstring>

#define CALIB_FILE "calib.txt"
#define MAX_BALLS 16
#define HANDLE_RADIUS 20.0f
#define GRID_DIV 8
#define BLOB_MIN_AREA 500

static cv::Scalar HSV_RED_LO(0, 100, 100);
static cv::Scalar HSV_RED_HI(10, 255, 255);
static cv::Scalar HSV_RED2_LO(160, 100, 100);
static cv::Scalar HSV_RED2_HI(180, 255, 255);
static cv::Scalar HSV_GREEN_LO(35, 100, 100);
static cv::Scalar HSV_GREEN_HI(85, 255, 255);

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

static int detectBallCount(const cv::Mat& frame) {
    cv::Mat hsv, mask;
    cv::cvtColor(frame, hsv, cv::COLOR_BGR2HSV);

    cv::Mat maskR1, maskR2, maskG;
    cv::inRange(hsv, HSV_RED_LO, HSV_RED_HI, maskR1);
    cv::inRange(hsv, HSV_RED2_LO, HSV_RED2_HI, maskR2);
    cv::inRange(hsv, HSV_GREEN_LO, HSV_GREEN_HI, maskG);

    mask = maskR1 | maskR2 | maskG;

    cv::Mat kernel = cv::getStructuringElement(cv::MORPH_ELLIPSE, {7, 7});
    cv::dilate(mask, mask, kernel, cv::Point(-1, -1), 2);
    cv::erode(mask, mask, kernel, cv::Point(-1, -1), 1);

    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(mask, contours, cv::RETR_EXTERNAL, cv::CHAIN_APPROX_SIMPLE);

    int count = 0;
    for (auto& c : contours) {
        if (cv::contourArea(c) >= BLOB_MIN_AREA) count++;
    }
    if (count > MAX_BALLS) count = MAX_BALLS;
    if (count < 1) count = 1;
    return count;
}

int main(int argc, char* argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0 || strcmp(argv[i], "-v") == 0) {
            std::cout << "tracker " << VERSION_STRING << std::endl;
            return 0;
        }
    }

    int numBalls = 1;
    for (int i = 1; i < argc; i++) {
        int n = std::atoi(argv[i]);
        if (n >= 1 && n <= MAX_BALLS) { numBalls = n; break; }
    }

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

    InitWindow(frameWidth, frameHeight, "Tracker " VERSION_STRING);
    SetTargetFPS(60);

    Font font = LoadFontEx("terminus.ttf", 20, NULL, 0);
    if (font.texture.id <= 0) font = GetFontDefault();
    else SetTextureFilter(font.texture, TEXTURE_FILTER_POINT);

    SDL_Init(SDL_INIT_AUDIO);
    Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 1024);
    int mixCh = 4 * numBalls;
    if (mixCh > 8) mixCh = 8;
    Mix_AllocateChannels(mixCh);

    Mix_Chunk* tracks[8] = {0};
    for (int i = 0; i < mixCh; i++) {
        tracks[i] = Mix_LoadWAV(TextFormat("samples/track%d.wav", i + 1));
        if (tracks[i]) Mix_PlayChannel(i, tracks[i], -1);
    }
    for (int i = 0; i < mixCh; i++) Mix_Volume(i, 0);

    loadCalib(frameWidth, frameHeight);

    std::vector<cv::Rect> bboxes(numBalls, cv::Rect(100, 100, 80, 80));
    std::vector<cv::Ptr<cv::TrackerCSRT>> trackers(numBalls);
    std::vector<bool> ok(numBalls, false);
    for (int i = 0; i < numBalls; i++) {
        bboxes[i].x = 100 + (i * 90) % (frameWidth - 200);
        bboxes[i].y = 100 + (i * 70) % (frameHeight - 200);
        trackers[i] = cv::TrackerCSRT::create();
        trackers[i]->init(frame, bboxes[i]);
        ok[i] = true;
    }

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

    while (!WindowShouldClose()) {
        cap >> frame;
        if (frame.empty()) break;

        cv::Point2f src[4] = {corners[0], corners[1], corners[2], corners[3]};
        cv::Point2f dst[4] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};
        cv::Mat H = cv::getPerspectiveTransform(src, dst);
        cv::Mat Hinv = H.inv();

        for (int i = 0; i < numBalls; i++) {
            ok[i] = trackers[i]->update(frame, bboxes[i]);
            int ch = 4 * i;
            if (ok[i]) {
                float cx = (float)bboxes[i].x + (float)bboxes[i].width / 2.0f;
                float cy = (float)bboxes[i].y + (float)bboxes[i].height / 2.0f;
                cv::Point2f p(cx, cy);
                std::vector<cv::Point2f> srcPts = {p};
                std::vector<cv::Point2f> dstPts;
                cv::perspectiveTransform(srcPts, dstPts, H);
                double u = dstPts[0].x;
                double v = dstPts[0].y;
                if (u < 0) u = 0; if (u > 1) u = 1;
                if (v < 0) v = 0; if (v > 1) v = 1;
                if (ch < mixCh)     Mix_Volume(ch,     (int)((1.0 - v) * 128));
                if (ch + 1 < mixCh) Mix_Volume(ch + 1, (int)(v * 128));
                if (ch + 2 < mixCh) Mix_Volume(ch + 2, (int)((1.0 - u) * 128));
                if (ch + 3 < mixCh) Mix_Volume(ch + 3, (int)(u * 128));
            } else {
                if (ch < mixCh)     Mix_Volume(ch,     0);
                if (ch + 1 < mixCh) Mix_Volume(ch + 1, 0);
                if (ch + 2 < mixCh) Mix_Volume(ch + 2, 0);
                if (ch + 3 < mixCh) Mix_Volume(ch + 3, 0);
            }
        }

        if (IsKeyPressed(KEY_S)) saveCalib();
        if (IsKeyPressed(KEY_R)) loadCalib(frameWidth, frameHeight);

        if (IsKeyPressed(KEY_C)) {
            int detected = detectBallCount(frame);
            if (detected != numBalls) {
                numBalls = detected;
                mixCh = 4 * numBalls;
                if (mixCh > 8) mixCh = 8;
                Mix_AllocateChannels(mixCh);
                bboxes.resize(numBalls, cv::Rect(100, 100, 80, 80));
                trackers.resize(numBalls);
                ok.resize(numBalls, false);
                for (int i = 0; i < numBalls; i++) {
                    bboxes[i].x = 100 + (i * 90) % (frameWidth - 200);
                    bboxes[i].y = 100 + (i * 70) % (frameHeight - 200);
                    trackers[i] = cv::TrackerCSRT::create();
                    trackers[i]->init(frame, bboxes[i]);
                    ok[i] = true;
                }
                for (int i = 0; i < mixCh; i++) Mix_Volume(i, 0);
            }
        }

        Vector2 mouse = GetMousePosition();
        cv::Point2f mp((float)mouse.x, (float)mouse.y);
        if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT)) {
            dragIdx = nearestCorner(mp);
            dragging = dragIdx >= 0;
        } else if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) {
            dragging = false;
            dragIdx = -1;
        }
        if (dragging && dragIdx >= 0) corners[dragIdx] = mp;

        cv::cvtColor(frame, rgbFrame, cv::COLOR_BGR2RGB);
        gridLines(rgbFrame, Hinv);
        raylibImage.data = rgbFrame.data;

        Texture2D texture = LoadTextureFromImage(raylibImage);

        BeginDrawing();
        ClearBackground(RAYWHITE);
        DrawTexture(texture, 0, 0, WHITE);

        for (int i = 0; i < 4; i++) {
            Color c = (i < 2) ? (Color){255, 80, 80, 255} : (Color){80, 80, 255, 255};
            DrawCircle((int)corners[i].x, (int)corners[i].y, 8, c);
        }

        for (int i = 0; i < numBalls; i++) {
            Color c = (i % 2 == 0) ? RED : GREEN;
            if (ok[i]) {
                DrawRectangleLinesEx(
                    (Rectangle){(float)bboxes[i].x, (float)bboxes[i].y, (float)bboxes[i].width, (float)bboxes[i].height},
                    3.0f, c
                );
                DrawTextEx(font, TextFormat("B%d", i + 1),
                    {(float)bboxes[i].x, (float)bboxes[i].y - 20}, 18, 0.0f, c);
            } else {
                DrawTextEx(font, TextFormat("B%d Lost", i + 1),
                    {20, 20 + i * 30.0f}, 18, 0.0f, c);
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
            Color c = ((i / 4) % 2 == 0) ? RED : GREEN;
            DrawRectangle(bx, barY, bw, barH, (Color){c.r, c.g, c.b, 40});
            DrawRectangle(bx, barY + barH - (int)(fill * barH), bw, (int)(fill * barH), c);
            DrawRectangleLines(bx, barY, bw, barH, WHITE);
            DrawTextEx(font, TextFormat("T%d", i + 1),
                {(float)(bx + 4), (float)(barY + 2)}, 14, 0.0f, WHITE);
        }

        DrawTextEx(font, "Drag corners | S save | R reset | C calibrate",
            {10, 10}, 16, 0.0f, RAYWHITE);
        DrawTextEx(font, TextFormat("Balls: %d", numBalls),
            {10, (float)(frameHeight - 80)}, 16, 0.0f, RAYWHITE);

        EndDrawing();
        UnloadTexture(texture);
    }

    UnloadFont(font);
    for (int i = 0; i < 8; i++) if (tracks[i]) Mix_FreeChunk(tracks[i]);
    Mix_CloseAudio();
    SDL_Quit();
    cap.release();
    CloseWindow();
    return 0;
}
