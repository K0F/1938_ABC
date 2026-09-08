# TODO

Feature ideas and planned work for the tracker.

## Upcoming

- [ ] **Re-acquire lost trackers** — when a ball goes missing, run foreground detection to find and re-init the tracker automatically (currently just remains silent until restart)
- [ ] **433 MHz button decoding** — RCSwitch/433Utils map for the Solight 1L67T buttons on boxes B/C (code → sample), debounce + per-button payload routing to SDL_mixer
- [ ] **Volume smoothing** — ramp volume over a few frames on loss/gain to avoid clicks
- [ ] **Quadrant fill highlight** — tint the active rectified quadrant for each ball (currently only grid/crosshair drawn)
- [ ] **More robust ball count** — auto-detect how many balls are present instead of fixed CLI arg
- [ ] **Perspective calibration UI polish** — show quadrant labels (1–4) and axis indicators on the rectified plane
- [ ] **Configurable track file locations** — allow custom sample paths via argument

## Ideas / stretch

- [ ] Preset/crossfade between loop sets
- [ ] Per-track pan control from a third axis
- [ ] Record automation of ball trajectories
- [ ] Better color/contrast segmentation for ball detection over CSRT

## Done

- [x] v0.1.0 — perspective correction (4 draggable corners, grid, persistence), dynamic ball count, silence-on-loss
- [x] v0.0.2 — 4-track continuous looping amp-mod via SDL2_mixer
