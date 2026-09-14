# TODO

Feature ideas and planned work for the tracker.

## Upcoming

- [ ] **Re-acquire lost trackers** — when a ball goes missing, run foreground detection to find and re-init the tracker automatically (currently just remains silent until restart)
- [x] **433 MHz button decoding** — `sampler.c` for boxes B/C: EV1527 decoder over libgpiod (GPIO22) → SDL2_mixer one-shot, mapa.csv code→sample map, LCD 16×2 status, `--listen`/`--simulate` modes
- [ ] **Volume smoothing** — ramp volume over a few frames on loss/gain to avoid clicks
- [ ] **Quadrant fill highlight** — tint the active rectified quadrant for each ball (currently only grid/crosshair drawn)
- [x] **More robust ball count** — auto-detect how many balls are present instead of fixed CLI arg
- [ ] **Perspective calibration UI polish** — show quadrant labels (1–4) and axis indicators on the rectified plane
- [ ] **Configurable track file locations** — allow custom sample paths via argument

## Ideas / stretch

- [ ] Preset/crossfade between loop sets
- [ ] Per-track pan control from a third axis
- [ ] Record automation of ball trajectories
- [ ] Better color/contrast segmentation for ball detection over CSRT

## Done

- [x] v0.4.0 — git-derived version, terminus.ttf font, `--version` CLI, auto-detect ball count (C key), silence on no balls
- [x] v0.3.0 — 1938 Music interactive part mapping (4 tracks per ball in 2D quadrant space), default 1 ball
- [x] v0.1.0 — perspective correction (4 draggable corners, grid, persistence), dynamic ball count, silence-on-loss
- [x] v0.0.2 — 4-track continuous looping amp-mod via SDL2_mixer
