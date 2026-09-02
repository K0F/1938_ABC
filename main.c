#define VERSION_MAJOR 0
#define VERSION_MINOR 0
#define VERSION_PATCH 2
#define VERSION_STRING "0.0.2"

#include <opencv2/opencv.hpp>
#ifdef GRAY
#undef GRAY
#endif
#include <opencv2/tracking.hpp>
#include "raylib.h"
#include <SDL2/SDL.h>
#include <SDL2/SDL_mixer.h>
#include <iostream>

int main() {
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

    SDL_Init(SDL_INIT_AUDIO);
    Mix_OpenAudio(44100, MIX_DEFAULT_FORMAT, 2, 1024);
    Mix_AllocateChannels(4);

    Mix_Chunk* tracks[4];
    tracks[0] = Mix_LoadWAV("samples/track1.wav");
    tracks[1] = Mix_LoadWAV("samples/track2.wav");
    tracks[2] = Mix_LoadWAV("samples/track3.wav");
    tracks[3] = Mix_LoadWAV("samples/track4.wav");
    for (int i = 0; i < 4; i++) {
        if (tracks[i]) Mix_PlayChannel(i, tracks[i], -1);
    }

    cv::Rect bbox1(100, 100, 80, 80);
    cv::Rect bbox2(300, 200, 80, 80);

    cv::Ptr<cv::TrackerCSRT> tracker1 = cv::TrackerCSRT::create();
    cv::Ptr<cv::TrackerCSRT> tracker2 = cv::TrackerCSRT::create();

    tracker1->init(frame, bbox1);
    tracker2->init(frame, bbox2);

    Image raylibImage = {
        .data = frame.data,
        .width = frameWidth,
        .height = frameHeight,
        .mipmaps = 1,
        .format = PIXELFORMAT_UNCOMPRESSED_R8G8B8
    };

    cv::Mat rgbFrame;

    while (!WindowShouldClose()) {
        cap >> frame;
        if (frame.empty()) break;

        bool ok1 = tracker1->update(frame, bbox1);
        bool ok2 = tracker2->update(frame, bbox2);

        if (ok1) {
            float cx = (float)bbox1.x + (float)bbox1.width / 2.0f;
            float cy = (float)bbox1.y + (float)bbox1.height / 2.0f;
            int vol0 = (int)(cx / (float)frameWidth * 128);
            int vol1 = (int)(cy / (float)frameHeight * 128);
            Mix_Volume(0, vol0);
            Mix_Volume(1, vol1);
        }

        if (ok2) {
            float cx = (float)bbox2.x + (float)bbox2.width / 2.0f;
            float cy = (float)bbox2.y + (float)bbox2.height / 2.0f;
            int vol2 = (int)(cx / (float)frameWidth * 128);
            int vol3 = (int)(cy / (float)frameHeight * 128);
            Mix_Volume(2, vol2);
            Mix_Volume(3, vol3);
        }

        cv::cvtColor(frame, rgbFrame, cv::COLOR_BGR2RGB);
        raylibImage.data = rgbFrame.data;

        Texture2D texture = LoadTextureFromImage(raylibImage);

        BeginDrawing();
        ClearBackground(RAYWHITE);

        DrawTexture(texture, 0, 0, WHITE);

        if (ok1) {
            DrawRectangleLinesEx(
                (Rectangle){(float)bbox1.x, (float)bbox1.y, (float)bbox1.width, (float)bbox1.height},
                3.0f, RED
            );
            DrawText("Ball 1", (int)bbox1.x, (int)bbox1.y - 20, 18, RED);
        } else {
            DrawText("Ball 1 Lost", 20, 20, 20, RED);
        }

        if (ok2) {
            DrawRectangleLinesEx(
                (Rectangle){(float)bbox2.x, (float)bbox2.y, (float)bbox2.width, (float)bbox2.height},
                3.0f, GREEN
            );
            DrawText("Ball 2", (int)bbox2.x, (int)bbox2.y - 20, 18, GREEN);
        } else {
            DrawText("Ball 2 Lost", 20, 50, 20, GREEN);
        }

        int barH = 60;
        int barW = frameWidth / 4;
        int barY = frameHeight - barH - 10;

        for (int i = 0; i < 4; i++) {
            int vol = Mix_Volume(i, -1);
            float fill = (float)vol / 128.0f;
            int bx = i * barW + 5;
            int bw = barW - 10;
            Color c = (i < 2) ? RED : GREEN;
            DrawRectangle(bx, barY, bw, barH, (Color){c.r, c.g, c.b, 40});
            DrawRectangle(bx, barY + barH - (int)(fill * barH), bw, (int)(fill * barH), c);
            DrawRectangleLines(bx, barY, bw, barH, WHITE);
            DrawText(TextFormat("T%d", i + 1), bx + 4, barY + 2, 14, WHITE);
        }

        EndDrawing();

        UnloadTexture(texture);
    }

    for (int i = 0; i < 4; i++) Mix_FreeChunk(tracks[i]);
    Mix_CloseAudio();
    SDL_Quit();
    cap.release();
    CloseWindow();
    return 0;
}
