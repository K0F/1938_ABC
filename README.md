# Tracker

Webcam-based multi-track amplitude modulation player. Tracked balls control volume of audio loops via SDL2_mixer, with perspective-correction for angled camera setups.

## How it works

Each ball controls two audio loops via its perspective-corrected position:

- **Ball 1 (red)**: X-axis → Track 1 volume, Y-axis → Track 2 volume
- **Ball 2 (green)**: X-axis → Track 3 volume, Y-axis → Track 4 volume
- Additional balls (when tracked) follow the same pattern: ball *n* → tracks *2n* and *2n+1*
- All tracks loop continuously, volume modulated in real-time by ball position
- If a ball is not detected (lost), its tracks go **silent** (volume → 0)

## Perspective correction

The webcam view can be angled, foreshortening ball positions. Define a planar region with 4 draggable corner handles; ball positions are rectified through a homography before mapping to volume.

- **Drag** the 4 corner handles (red circles = X axis, blue circles = Y axis) to outline the tracking plane
- **S** — save calibration to `calib.txt` (auto-loaded next run)
- **R** — reset corners to the full frame
- A perspective grid + quadrant crosshair is overlaid so you can see the rectification

## Usage / arguments

```
./tracker [N]
```

- `N` — number of balls to track (default `2`, max `16`)
- Example: `./tracker 3` tracks three balls, controlling tracks 1–6

Trackers auto-initialize at startup at staggered positions; lost trackers attempt to re-acquire.

## Build

```
g++ main.c -o tracker -I/usr/include/opencv5 \
    $(pkg-config --cflags --libs sdl2 SDL2_mixer) \
    -lraylib -lopencv_core -lopencv_videoio -lopencv_video \
    -lopencv_imgproc -lopencv_calib -lopencv_geometry -lopencv_tracking \
    -lGL -lm -lpthread -ldl -lrt -lX11
```

## Run

Place WAV files as `samples/track1.wav` through `samples/track8.wav` (only those needed for your ball count), then:

```
./tracker
```

## Dependencies

- Raylib 6.x
- OpenCV 5.x (core, video, videoio, imgproc, calib, geometry, tracking)
- SDL2 + SDL2_mixer

## Controls

| Input | Action |
|-------|--------|
| Mouse drag | Move nearest corner handle |
| `S` | Save calibration to `calib.txt` |
| `R` | Reset corners to full frame |

## Files

- `main.c` — source
- `calib.txt` — saved perspective calibration (gitignored)
- `samples/` — audio loops

## Version

0.1.0
