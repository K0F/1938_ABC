# TODO

Feature ideas and planned work for the tracker.

## Hardware — Box A / Box B

- [ ] **Dokončit zesilovač v Boxu A** — CA-3110S + interní reproduktor LS40N 40 mm,
      panelový jack 3,5 mm (TIP=L, RING=R, SLEEPE=GND) paralelně přes Y-rozdvojku.
- [ ] **Dokončit zesilovač v Boxu B** — CA-3110S + interní reproduktor, stejné
      zapojení jako Box A.
- [ ] **Zapojit přijímač v Boxu B** — SRX882S 433 MHz na GPIO (viz `docs/SCH.md`),
      VCC/GND/Data proti pinům RPi, anténa drát cca λ/4. Bez přijímače tlačítka
      neslyší sampler.
- [ ] **Vyzkoušet asociaci tlačítek u B** — párování Solight 1L67T probíhá na
      samotném tlačítku (learning-code EV1527, držet PAIR na ovladači), kódy se pak
      namapují na samply. Postup: `sudo ./sampler --box b --listen` vypíše kód
      každého stisku, z nich se sestaví `mapa.csv` (kód,vzorek). Bez `mapa.csv`
      sampler jen tiskne kódy a nic nehraje. Kritérium: 10 tlačítek hraje 8 různých
      vzorků a kódy se po restartu neopakují. Ověřit i bez RF adaptéru přes
      `printf 'kód\n' | ./sampler --box b --simulate`.
- [ ] **Dokončit přípojku Boxu B** — napájení 230 V samostatnou 5 m šňůrou JT003 do
      zásuvky/odbočky (kapitola 4 v `HW.md`), kabely stažené, 2denní zátěžový test
      (`docs/BUILD.md` §8).

## Upcoming

- [ ] **Re-acquire lost trackers** — when a ball goes missing, run foreground detection to find and re-init the tracker automatically (currently just remains silent until restart)
- [x] **433 MHz button decoding** — `sampler.c` for box B: EV1527 decoder over libgpiod (GPIO22) → SDL2_mixer one-shot, mapa.csv code→sample map, LCD 16×2 status, `--listen`/`--simulate` modes
- [ ] **Volume smoothing** — ramp volume over a few frames on loss/gain to avoid clicks
- [ ] **Quadrant fill highlight** — tint the active rectified quadrant for each ball (currently only grid/crosshair drawn)
- [x] **More robust ball count** — auto-detect how many balls are present instead of fixed CLI arg
- [ ] **Perspective calibration UI polish** — show quadrant labels (1–4) and axis indicators on the rectified plane
- [ ] **Configurable track file locations** — allow custom sample paths via argument
- [ ] **Calibration hotkey in headless mode** — today `S`/`R`/`C` need a window, so
      calibration means a temporary HDMI session; a web/UDP command would avoid it

## Ideas / stretch

- [ ] Preset/crossfade between loop sets
- [ ] Per-track pan control from a third axis
- [ ] Record automation of ball trajectories
- [ ] Better color/contrast segmentation for ball detection over CSRT

## Done

- [x] v0.5.1 — Box A headless: `tracker --headless` + `tracker.service` (User=pi),
      SIGTERM/SIGINT graceful stop, journal logging; okno zůstává jen pro kalibraci
- [x] v0.5.1 — build opraven pro Raspberry Pi OS / Debian: `Makefile` detekce OpenCV
      přes pkg-config (`-lopencv_geometry` neexistuje v OpenCV 4.x), raylib install
      s `RAYLIB_LIBTYPE=SHARED` v `install-deps.sh` i `Dockerfile.arm64-test`,
      `libopencv-contrib-dev` pro CSRT
- [x] v0.5.0 — faktury: DRAFT vodoznak, `docs/md2pdf.py --watermark`
- [x] v0.4.0 — git-derived version, terminus.ttf font, `--version` CLI, auto-detect ball count (C key), silence on no balls
- [x] v0.3.0 — 1938 Music interactive part mapping (4 tracks per ball in 2D quadrant space), default 1 ball
- [x] v0.1.0 — perspective correction (4 draggable corners, grid, persistence), dynamic ball count, silence-on-loss
- [x] v0.0.2 — 4-track continuous looping amp-mod via SDL2_mixer
