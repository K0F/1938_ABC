# TODO

Feature ideas and planned work for the tracker.

## Hardware — Box A / Box B

- [ ] **AXAGON ADA-17 fyzicky přepojit** — USB zvuková karta boxu byla při testu
      odpojena přes `/sys/bus/usb/drivers/usb/unbind` a na Raspberry Pi OS s
      jádrem 6.12 se zařízení po unbindu samo nevrátí (`bind` → `No such
      device`), takže ji musí někdo vyjmout a vložit zpět. Zvuk se po připojení
      sám dožene (udev → `box-sound-restart` → restart trackera)

- [ ] **Dokončit zesilovač v Boxu A** — CA-3110S + interní reproduktor LS40N 40 mm,
      panelový jack 3,5 mm (TIP=L, RING=R, SLEEVE=GND) paralelně přes Y-rozdvojku.
      Z výstupu AXAGONu 3,5 mm do vstupu CA-3110S je potřeba **redukce 3,5 → 6,3 mm**
      (příp. 3,5 mm ↔ 2× RCA), viz `HW.md` §5.3.
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
- [ ] **Kalibrace v HDMI konzoli** — dnes jde `S`/`R`/`C` jen v okně a myš
      táhne po souřadnicích snímku; v konzoli se okno zvětší na 1920x1080, takže
      by se hodilo ukázat, že se dokládek počítá v souřadnicích kamery (a
      třeba zrcadlit ovládání na druhém monitoru)
- [ ] **Přehodí USB kamery v konzoli** — zvuková karta má obnovu přes udev, ale
      když se přehodí kamera, tracker v konzoli umře a cyklus ho sice zvedne,
      čeká se na `/dev/video0`; u USB kamery to chvíli trvá a hlídá se to jen
      při startu relace, ne za běhu
- [ ] **Softwarový GL v konzoli** — běží na `LIBGL_ALWAYS_SOFTWARE=1`, protože
      hardwarový GLX na tomhle Pi neumí pro GLFW kontext (`GLXBadFBConfig`).
      Kdyby se to na novějším jádře opravilo, přepnout na `BOX_CONSOLE_SOFTGL=0`
      a ušetřit dvě jádra CPU
- [ ] **Calibration hotkey in headless mode** — today `S`/`R`/`C` need a window, so
      calibration means a temporary HDMI session; a web/UDP command would avoid it

## Ideas / stretch

- [ ] Preset/crossfade between loop sets
- [ ] Per-track pan control from a third axis
- [ ] Record automation of ball trajectories
- [ ] Better color/contrast segmentation for ball detection over CSRT

## Done

- [x] v0.5.1 — HDMI konzole pro Box A: autologin na `tty1` + okno trackeru na
      celou TV (`box-console.sh on|off|status`, `box-console.xinit`,
      `getty-tty1-autologin.conf`). Snímek 640x480 se v okně 1920x1080 vejde
      svisle (pillarbox) — okno se rozjede na velikost monitoru, ne přes
      `FLAG_FULLSCREEN_MODE` (ten přepíná výstup na 640x480, kde okno nevznikne).
      Relace běží na Mesa softwarovém GL, protože hardwarový GLX tady GLFW
      kontext nevytvoří. Testy: `tests/test-box-console.sh`
- [x] v0.5.1 — autostart po restartu odolný proti pomalé kameře: `StartLimitIntervalSec=0`
      v `tracker.service` (jinak systemd po 5 restartech za 2 s shodí jednotku do
      `failed`), tracker bez zvukové karty končí nenulově a čeká na ni v restartu
- [x] v0.5.1 — přehození USB zvukové karty už nezabije zvuk napámo: `box-sound-restart.sh`
      + `.service` + udev pravidlo `99-box-sound.rules` přenastaví ALSA a restartují
      službu, karty v `/etc/asound.conf` podle jména (`hw:CARD=Adapter,DEV=0`).
      Ověřeno na boxu unbind/bind USB zařízení i po bootu; pravidlo musí dělat
      `TAG+="systemd"`, jinak systemd-udevd `SYSTEMD_WANTS` neřeší
- [x] v0.5.1 — `box-audio-test.sh` bez `sudo` řekne proč, a tracker po testu
      vždy pustí zpět (test už nezanechá box tichý)
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
