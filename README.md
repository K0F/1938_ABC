# Tracker

Webcam-based 4-track amplitude modulation player. Two tracked balls control volume of 4 audio loops via SDL2_mixer.

## How it works

- **Ball 1 (red)**: X-axis → Track 1 volume, Y-axis → Track 2 volume
- **Ball 2 (green)**: X-axis → Track 3 volume, Y-axis → Track 4 volume
- All 4 tracks loop continuously, volume modulated in real-time by ball position

## Build

```
g++ main.c -o tracker -I/usr/include/opencv5 \
    $(pkg-config --cflags --libs sdl2 SDL2_mixer) \
    -lraylib -lopencv_core -lopencv_videoio -lopencv_video \
    -lopencv_imgproc -lopencv_tracking -lGL -lm -lpthread -ldl -lrt -lX11
```

## Run

Place 4 WAV files as `samples/track1.wav` through `samples/track4.wav`, then:

```
./tracker
```

## Dependencies

- Raylib 6.x
- OpenCV 5.x (with tracking module)
- SDL2 + SDL2_mixer

## Version

0.0.2
