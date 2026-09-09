# Postup stavby — Tracker (3 boxy)

Kompletní návod k sestavení třídílného hudebního nástroje Tracker.
Text navazuje na [`HW.md`](../HW.md) (soupis součástek) a [`docs/SCH.md`](SCH.md) (schémata zapojení).

---

## 1) Předpoklady

### 1.1 Nářadí

| Nástroj | Účel |
|---------|------|
| Šroubovák křížový PH1/PH2 | Montáž Pi 4 na sloupky, svorkovnice |
| Letovací pájka + cín | Pájení vodičů na jack EY-512C, LED, tlačítko |
| Vrták Ø6 mm | Otvor pro panelový jack na čelní stěně |
| Multimetr | Kontrola propojení, měření napětí |
| Krimpovací kleště (volitelné) | Pokud používáte krimpovací konektory |
| Termokamera (volitelné) | Zátěžový test — tepelné stopy na kabeláži |

### 1.2 Software na PC (pro generování dokumentace)

```bash
# Debian / Ubuntu / Raspberry Pi OS
sudo apt install graphviz python3 python3-pip python3-gi libpango1.0-dev
pip3 install markdown pikepdf pycairo

# Arch / Manjaro
sudo pacman -S graphviz python python-markdown python-pikepdf python-cairo python-gobject pango
```

### 1.3 Přehled systému

Sestava se skládá ze tří krabiček (všechny Pi 4 Model B 4 GB):

- **Box A** — Hlavní jednotka, běží tracker (webkamera snímá koule). Webkamera + stativ, HDMI, USB zvukovka → jack. Napájení: vlastní zdroj 15,3 W
- **Box B** — Sampler, 10 tlačítek, LCD displej, interní reproduktor. SRX882S, LCD 16×2, CA-3110S + LS40N, Y-rozdvojka. Napájení: vlastní zdroj 15,3 W
- **Box C** — Identický s B (dalších 10 tlačítek). Stejné zapojení jako B. Napájení: vlastní zdroj 15,3 W

Komunikace: tlačítka → RF 433 MHz → SRX882S v B/C → GPIO → SDL Mixer.
Synchronizace A↔B↔C: WiFi 2,4 GHz (rsync).
Napájení: každý box má **vlastní zdroj 15,3 W** (5 V se mezi boxy nerozvádí). 230 V dorazí 10 m šňůrou do boxu A, odtud krátké 2 m šňůry do B a C — do každého boxu vstoupí 230 V a ten si ho sám převede vlastním zdrojem.

---

## 2) Nákup součástek

Kompletní seznamy s odkazy na e-shopy viz [`HW.md`](../HW.md) §2–3 a [`nakup.txt`](../nakup.txt).

### 2.1 Alza.cz

| Položka | Kusy | ≈ Cena |
|---------|-----:|-------:|
| Raspberry Pi 4 Model B 4 GB | 3 | 9 087 Kč |
| Inter-Tech ODS-721 (krabička) | 3 | 777 Kč |
| Zdroj RPi 15,3 W USB-C | 3 | od 753 Kč |
| USB zvuková karta (Gembird) | 3 | ≈450 Kč |
| microSD 64 GB (A) + 32 GB (B/C) | 3 | ≈1 550 Kč |
| Webkamera Logitech C920 | 1 | 1 599 Kč |
| micro-HDMI → HDMI kabel 1,8 m | 1 | 109 Kč |
| Stativ Apexel Mini Tripod | 1 | 189 Kč |
| **Alza mezisoučet** | | **≈14 600 Kč** |

### 2.2 GME (gme.cz)

| Položka | Kusy | ≈ Cena |
|---------|-----:|-------:|
| MASZCZYK KM-85 (krabička) | 3 | 627 Kč |
| Flexo JT003 5 m + 2 m | 4 | 528 Kč |
| Lanko CYA, svorkovnice, bužírky, sloupky | — | ≈940 Kč |
| Jack EY-512C + rozdvojky | 5 | 95 Kč |
| LCD 16×2 + I2C adapter | 2 | ≈308 Kč |
| CA-3110S + LS40N | 2 | ≈222 Kč |
| SRX882S | 2 | 158 Kč |
| Solight 1L67T tlačítka | 20 | 1 452 Kč |
| **GME mezisoučet** | | **≈4 330 Kč** |

### 2.3 Celkový odhad

| | HW | Doprava | Práce (80 h) | Rezerva | **Celkem** |
|---|---:|---:|---:|---:|---:|
| Doporučená varianta | ≈18 500 | ≈400 | 28 000 | ≈1 900 | **≈48 800 Kč** |

---

## 3) Sestavení dokumentace (generování PDF)

Před montáží si vygenerujte PDF se schématy — budete je potřebovat jako referenci.

### 3.1 Instalace závislostí

```bash
# Graphviz (dot)
sudo apt install graphviz

# Python + knihovny
sudo apt install python3 python3-pip python3-gi libcairo2-dev libpango1.0-dev
pip3 install markdown pikepdf pycairo
```

### 3.2 Generování PDF

```bash
cd tracker
sh docs/build-docs.sh
```

Skript provede:
1. Všech 16 `.dot` souborů v `docs/dot/` → jednotlivé PDF přes `dot -Tpdf`
2. Sloučení `sch_*.pdf` → `docs/SCH.pdf` (schémata zapojení)
3. Sloučení `hw_*.pdf` → `docs/HW.pdf` (hardware požadavky)
4. Převod `SCH.md` → `docs/SCH.pdf` přes `md2pdf.py --pdf` (textová část)
5. Převod `HW.md` → `docs/HW.pdf` přes `md2pdf.py --pdf`
6. Převod `BUILD.md` → `docs/BUILD.pdf`

### 3.3 Výstup

| Soubor | Obsah |
|--------|-------|
| `docs/SCH.pdf` | Schémata zapojení všech propojení |
| `docs/HW.pdf` | Hardware požadavky a objednávkový list |
| `docs/BUILD.pdf` | Tento návod |

Případně přes Makefile:
```bash
make docs
```

---

## 4) Montáž — Box A (hlavní jednotka)

### 4.1 Vrtání krabičky KM-85

1. Na **čelní stěně** vyvrtejte otvor **Ø6 mm** pro panelový jack EY-512C.
2. Na **zadní stěně** vyvrtejte 2–3 otvory pro průchod kabelů (napájecí, USB).
3. Otvory opatřete gumovými průchodkami (proti ostrým hranám).

### 4.2 Montáž Pi 4

1. Na spodní desku krabičky přišroubujte 4× distanční sloupek M2,5 × 10 mm.
2. Pi 4 položte na sloupky a přišroubujte matkami M2,5.
3. **Důležité:** Pi 4 musí mít vzduchovou mezeru od stěn pro chlazení.

### 4.3 Připojení 230 V

Podrobné schéma: [`docs/SCH.md`](SCH.md) §2.1, [`docs/dot/sch_02_terminal_block.dot`](dot/sch_02_terminal_block.dot)

1. Přiveďte 10 m šňůru JT003 přes kabelovou průchodku do boxu A.
2. Připojte na **svorkovnici KLS 3pól**:
   - **L** (černý/hnědý) → svorka L
   - **N** (modrý) → svorka N
   - **PE** (žluto-zelený) → svorka PE — **nikdy nepřerušovat spínačem!**
3. Ze svorkovnice odbočte **dvě krátké 2 m šňůry JT003** → ven z boxu k boxům B a C (do nich vstoupí jen 230 V).
4. Zbývající vývod → kabel oficiálního zdroje RPi 15,3 W (každý box má svůj vlastní zdroj — 5 V se mezi boxy nerozvádí).

### 4.4 Zapojení GPIO — reset + LED

Schéma: [`docs/SCH.md`](SCH.md) §2.4, [`docs/dot/sch_05_gpio_a.dot`](dot/sch_05_gpio_a.dot)

| Komponenta | Připojení |
|------------|-----------|
| Mikrospínač 6×6 mm (NO) | GPIO17 (pin 11) → tlačítko → GND (pin 6) |
| Pull-up rezistor 10 kΩ | GPIO17 (pin 11) → 10 kΩ → 3V3 (pin 1) |
| LED 5 mm + 330 Ω | GPIO26 (pin 37) → 330 Ω → LED [+] → GND (pin 9) |

- Krátký stisk = `systemctl poweroff`, dvojitý stisk = restart.
- Pull-up může být i interní, externí 10 kΩ je bezpečnější.

### 4.5 Připojení USB periferií

Schéma: [`docs/SCH.md`](SCH.md) §2.3

1. **Webkamera** (Logitech C920) → USB-A port Pi 4 → na stativ nad hrací plochu.
2. **USB zvuková karta** (Gembird) → USB-A port Pi 4.
3. **micro-HDMI** → HDMI kabel 1,8 m → monitor (pro setup/konzoli).
4. **Interní 3,5 mm jack Pi 4 se NEPOUŽÍVÁ** — audio vždy přes USB zvukovku.

### 4.6 Montáž panelového jacku

Schéma: [`docs/SCH.md`](SCH.md) §8, [`docs/dot/sch_10_audio_jack.dot`](dot/sch_10_audio_jack.dot)

1. Jack EY-512C vložte do otvoru Ø6 mm na čelní stěně.
2. Přitáhněte maticí (motýlek) zevnitř.
3. Pájení:
   - **TIP (špička)** = L (levý kanál) — pájecí bod uprostřed
   - **RING (kroužek)** = R (pravý kanál) — pájecí bod na straně
   - **SLEEVE (plášť)** = GND — pájecí bod na pouzdru
4. Připojte vodiče z USB zvukovky (3,5 mm stereo OUT).

### 4.7 Instalace OS a softwaru

```bash
# 1. Nahrajte Raspberry Pi OS Lite na microSD 64 GB
# 2. Po prvním spuštění:
sudo apt update && sudo apt upgrade -y
sudo apt install -y git cmake pkg-config libopencv-dev
sudo apt install -y libasound2-dev libsdl2-dev libsdl2-mixer-dev

# 3. Nainstalujte raylib (postup dle raylib/docs/INSTALL.md)
git clone https://github.com/raysan5/raylib.git /tmp/raylib
cd /tmp/raylib/src && make PLATFORM=PLATFORM_DESKTOP
sudo make install RAYLIB_INSTALL_PATH=/usr/local/lib RAYLIB_H_INSTALL_PATH=/usr/local/include

# 4. Sestavte tracker
cd /home/pi/tracker
make

# 5. Nakopírujte vzorky
# samples/track1.wav .. track4.wav

# 6. Otestujte
./tracker 1
```

---

## 5) Montáž — Box B/C (sampler)

Postup je pro B i C **identický**. Liší se pouze přiřazení tlačítek a vzorků.

### 5.1 Vrtání krabičky KM-85

1. **Čelní stěna:** otvor Ø6 mm pro jack EY-512C.
2. **Boční nebo čelní stěna:** otvor pro reproduktor LS40N (40 mm).
3. **Zadní stěna:** 2–3 otvory pro kabely (napájecí, USB, repro).
4. Případně otvor pro LED a tlačítko reset.

### 5.2 Montáž Pi 4

Stejný postup jako §4.2 — 4× sloupek M2,5, Pi 4 na sloupky.

### 5.3 Připojení 230 V

1. Přiveďte **2 m šňůru JT003** z boxu A (odbočka ze svorkovnice) — do boxu vstoupí jen 230 V.
2. Připojte na svorkovnici KLS (nebo přímo) → kabel zdroje RPi 15,3 W (box má svůj vlastní zdroj).

### 5.4 Zapojení GPIO

Schéma: [`docs/SCH.md`](SCH.md) §3, [`docs/dot/sch_06a_box_b_gpio.dot`](dot/sch_06a_box_b_gpio.dot)

#### LCD 16×2 (I2C přes PCF8574)

| Pi GPIO (pin) | LCD modul |
|---------------|-----------|
| 3V3 (pin 1) | VCC |
| GND (pin 6) | GND |
| GPIO 2 / SDA (pin 3) | SDA |
| GPIO 3 / SCL (pin 5) | SCL |

- Pull-upy 4,7 kΩ na SDA/SCL (případně integrované v modulu).
- Adresa: **0x27** — ověřit `i2cdetect -y 1`.
- Aktivace I2C: `sudo raspi-config` → Interface → I2C → Enable.

#### SRX882S (RF přijímač 433 MHz)

| SRX882S | Pi GPIO (pin) |
|---------|---------------|
| VCC | 3V3 (pin 1) |
| DATA | GPIO22 (pin 15) |
| GND | GND (pin 6) |
| ANT | integrovaná anténa (PCB) |

- Modul držet **≥2 cm od Pi** (rušení).
- Napájet **3V3** (ne 5V — DATA pak má 5V logiku → převodník).

#### Reset tlačítko + LED

Stejný postup jako §4.4 (GPIO17 + GPIO26).

### 5.5 Audio řetězec

Schéma: [`docs/SCH.md`](SCH.md) §3, [`docs/dot/sch_06b_box_b_audio.dot`](dot/sch_06b_box_b_audio.dot)

1. USB zvuková karta → 3,5 mm stereo OUT.
2. **Y-rozdvojka PremiumCord** (JACK 3,5 M → 2× JACK 3,5 F):
   - Větev 1 → panelový jack EY-512C (výstup na mix/zesilovač).
   - Větev 2 → zesilovač CA-3110S → reproduktor LS40N (interní repro).
3. CA-3110S: napájení z 5V rozvodu boxu, jeden kanál stačí (stereo→mono přes rezistory).

### 5.6 Montáž reproduktoru

1. Reproduktor LS40N (40 mm) připevněte do otvoru v krabičce (šrouby nebo lepidlem).
2. Vodiče připojte na výstup zesilovače CA-3110S.

### 5.7 Instalace OS a softwaru

Stejný postup jako §4.7, ale:
- microSD **32 GB** (postačí).
- Navíc nainstalovat `librc-switch` pro dekódování 433 MHz.
- Nakonfigurovat I2C: `sudo raspi-config` → Interface → I2C → Enable.

---

## 6) Spárování tlačítek (433 MHz)

### 6.1 Zapsání kódů

1. Spusťte na Pi B/C program, který čte kódy z SRX882S (příklad v `rc-switch`).
2. Každým tlačítkem Solight 1L67T stiskněte a zapište přijatý kód.
3. Vytvořte soubor `mapa.csv`:

```csv
# B box (Pi na adrese B): kód → sample
12200123, sample_b_01.wav
12200124, sample_b_02.wav
12200125, sample_b_03.wav
...
```

### 6.2 Přiřazení

| Tlačítka | Box | Vzorky |
|----------|-----|--------|
| B01–B10 | B | sample_b_01 .. sample_b_10 |
| C01–C10 | C | sample_c_01 .. sample_c_10 |

### 6.3 Test dosahu

1. Zavřete víko boxu.
2. Odejděte s tlačítkem 30–60 m.
3. Ověřte příjem (typická odezva 30–80 ms).
4. Pokud dosah nestačí: zkontrolujte orientaci antény SRX882S, vzdálenost od Pi.

---

## 7) Konfigurace a kalibrace

### 7.1 WiFi synchronizace A↔B↔C

1. Všechny 3 Pi připojte na stejnou WiFi síť (2,4 GHz).
2. Nastavte SSH přístup mezi nimi.
3. Vzorky nakopírujte z A do B/C:
   ```bash
   # Na Pi A:
   rsync -avz samples/ pi@B_IP:/home/pi/tracker/samples/
   rsync -avz samples/ pi@C_IP:/home/pi/tracker/samples/
   ```

### 7.2 Kalibrace perspektivy (Box A)

Podrobnosti v [`README.md`](../README.md) §Perspective correction:

1. Spusťte `./tracker 1` na Pi A s připojeným monitorem (HDMI).
2. Přetáhněte 4 rohy (červené = X, modré = Y) kolem hrací plochy.
3. Stiskněte **S** pro uložení kalibrace do `calib.txt`.

### 7.3 Test audio výstupů

1. Na každém boxu spusťte přehrávání vzorků.
2. Ověřte zvuk na panelovém jacku (TIP=L, RING=R, SLEEVE=GND).
3. U B/C ověřte i interní reproduktor přes CA-3110S.

---

## 8) Zátěžový test

Před finální instalací spusťte 2denní test:

| Test | Postup | Kritérium |
|------|--------|-----------|
| RF dosah | Stisk tlačítka ze 30 m se zavřeným víkem | Příjem 100 % |
| Baterie | Nechat tlačítka aktivní 48 h | Žádný výpadek |
| Teplota | Změřit termokamerou po 4 h běhu | Žádné tepelné stopy na kabeláži |
| Audio | Přehrávat vzorky 24 h nepřetržitě | Žádné přeslechy, clicky |
| Synchronizace | Spustit A+B+C současně | Vzorky synchronizované |

---

## 9) Řešení problémů

| Problém | Řešení |
|---------|--------|
| `cannot find -lraylib` | `sudo apt install x11-repo && sudo apt install raylib` (Termux) nebo sestavit ze zdroje |
| `cannot find -lGL` | `sudo apt install mesa` (Termux) |
| LCD nezobrazuje | `i2cdetect -y 1` — ověřte adresu 0x27; zkontrolujte I2C pull-upy; zkontrolujte `dtparam=i2c_arm=on` v `/boot/config.txt` |
| Opencv build selže (Qt6) | Na Termux: `build_termux.sh` automaticky builduje OpenCV bez Qt (~15–25 min) |
| Žádný zvuk | Ověřte `aplay -l` — USB zvukovka musí být viditelná; nastavte `SDL_AUDIODRIVER=alsa` |
| Tlačítka nepřijímají | Zkontrolujte napájení SRX882S (3V3, ne 5V); ověřte GPIO22; modul ≥2 cm od Pi |
| LED nesvítí | Zkontrolujte polaritu LED (delší noha = +); rezistor 330 Ω |
| Tracker nesleduje koule | Kalibrace (`S`), osvětlení, kontrast pozadí |

---

## 10) Dokumentace a odkazy

| Soubor | Popis |
|--------|-------|
| [`README.md`](../README.md) | Softwarový návod, kalibrace, ovládání |
| [`HW.md`](../HW.md) | Seznam součástek, ceny, objednávky |
| [`docs/SCH.md`](SCH.md) | Kompletní schémata zapojení |
| [`docs/BUILD.md`](BUILD.md) | Tento návod |
| [`docs/dot/`](dot/) | Graphviz zdrojáky schémat |
| [`docs/build-docs.sh`](build-docs.sh) | Skript pro generování PDF |
| [`nakup.txt`](../nakup.txt) | Ověřený nákupní seznam |

Verze: 9. 9. 2026
