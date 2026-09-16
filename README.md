# Multi-Track Audio Tracker & RF Sampler

Tento repozitář obsahuje dvě hlavní aplikace vytvořené pro interaktivní zvukovou instalaci:
1. **Tracker (Box A)**: Přehrávač s amplitudovou modulací více stop založený na webkameře. Sledované barevné míčky ovládají hlasitost zvukových smyček s korekcí perspektivy.
2. **Sampler (Box B & C)**: Bezdrátový sampler, ve kterém 433 MHz RF tlačítka spouští jednorázové zvukové samply.

**Režie:** Barbora Jeřábková  
**Realizace:** Pavel Sterec, Matouš Hakela, Kryštof Pešek  
**Produkce:** Jakub Beran

---

## 1. Tracker (Box A)

Tracker používá webkameru k detekci polohy fyzických míčků (až 16) a mapuje jejich X/Y souřadnice na hlasitost neustále hrajících zvukových stop.

### Jak to funguje
Každý sledovaný míček ovládá čtyři zvukové smyčky:
- **Míček 1 (červený)**: Osa Y (nahoře) -> Stopa 1, Osa Y (dole) -> Stopa 2, Osa X (vlevo) -> Stopa 3, Osa X (vpravo) -> Stopa 4
- **Míček 2 (zelený)**: Ovládá stopy 5-8 podle stejného vzoru, a tak dále.
- Všechny stopy se neustále opakují a hlasitost je modulována v reálném čase podle polohy míčku.
- Pokud míček není detekován (je ztracen), jeho stopy **ztichnou** (hlasitost = 0). Ztracené trackery se automaticky pokusí znovu cíl zaměřit.

### Korekce perspektivy
Pokud je webkamera nakloněna, může být sledovaná plocha zkreslená. Software to koriguje pomocí homografické projekce.
- **Táhnutím** 4 rohových bodů (červené kruhy = osa X, modré kruhy = osa Y) ohraničíte reálnou sledovanou plochu.
- **S** – uloží kalibraci do `calib.txt` (automaticky se načte při dalším spuštění).
- **R** – resetuje rohy na plný snímek.
Pro snazší vizualizaci rektifikace je přes obraz překryta perspektivní mřížka.

### Závislosti (Tracker)
| Knihovna | Verze | Poznámky |
|---------|---------|-------|
| Raylib | 5.x-6.x | Vykreslování oken a vstup |
| OpenCV | 4.x-5.x | Zpracování obrazu, kalibrace, sledování |
| SDL2 + SDL2_mixer | 2.x | Přehrávání zvuku a ovládání hlasitosti |

### Sestavení (Desktop Linux)
```bash
make
```

### Sestavení (Android / Termux)
Rychlá instalace v čistém Termuxu bez dalších závislostí:
```bash
git clone <repo-url> tracker
cd tracker
bash build_termux.sh # Jednorázová instalace a sestavení
```
*(Pro manuální kroky a řešení problémů na Termuxu viz sekci [Řešení problémů](#řešení-problémů))*

### Spuštění Trackeru
Umístěte své WAV soubory jako `samples/track1.wav` až `samples/track8.wav` do složky `samples`, poté spusťte tracker:
```bash
# ./tracker [počet_míčků]
./tracker 2  # Sleduje 2 míčky, ovládá stopy 1-8
```

### Ovládání (Tracker)
| Vstup | Akce |
|-------|--------|
| Tažení myší / Dotyk | Přesun nejbližšího rohového bodu |
| `S` | Uloží kalibraci do `calib.txt` |
| `R` | Resetuje rohy na celý obraz |

---

## 2. Sampler (Boxy B & C)

Sampler funguje jako samostatná bezdrátová spouštěcí jednotka. Využívá 433 MHz RF přijímač pro příjem signálů z 20 bezdrátových tlačítek (Solight 1L67T, protokol EV1527) a přehrává jednorázové zvukové samply přes `SDL2_mixer`. Také může volitelně aktualizovat stav úderů na 16×2 I2C displeji.

- RF kódy jsou dekódovány nativně na **GPIO22** pomocí interního EV1527 dekodéru přes `libgpiod` (není potřeba rc-switch/wiringPi).
- Samply jsou jednorázové a spouští se znovu při každém stisknutí.
- Identita boxu (`b` nebo `c`) určuje, jaké samply a jaký mapovací soubor se použijí.

### Sestavení (Raspberry Pi OS)
```bash
sudo apt install -y libgpiod-dev libsdl2-dev libsdl2-mixer-dev
make sampler
```
*Poznámka: Na PC bez GPIO se sampler stále úspěšně sestaví a lze jej testovat v režimu `--simulate`.*

### Spuštění Sampleru
```bash
./sampler --box b [možnosti]
```

| Možnost | Výchozí | Význam |
|--------|---------|---------|
| `--box b\|c` | — | Identita boxu (vyžadováno, zobrazeno na LCD) |
| `--map SOUBOR` | `mapa.csv` | Soubor mapující kódy na samply |
| `--samples-dir SLOŽKA` | `samples` | Složka obsahující WAV soubory |
| `--lcd-addr HEX` | `0x27` | I2C adresa PCF8574 displeje, nebo `off` |
| `--te-us N` | `320` | Základní časování EV1527 v µs (nutno doladit pro každé tlačítko) |
| `--debounce-ms N` | `300` | Časové okno pro debounce každého tlačítka |
| `--listen` | — | Režim pouhého poslechu: vypíše každý detekovaný kód |
| `--simulate` | — | Načítá kódy ze standardního vstupu (stdin) místo RF přijímače |

### Mapování a nahrávání tlačítek
Použijte přepínač `--listen` ke zjištění desítkového RF kódu každého fyzického tlačítka:
```bash
./sampler --box b --listen
```
Stiskněte každé tlačítko a zkopírujte vypsaná čísla `code=` do `mapa.csv`. Formát:
```csv
12200123, sample_b_01.wav
```
Umístěte příslušné soubory (`sample_b_*.wav` nebo `sample_c_*.wav`) do složky `samples/`.

### Testování na desktopu
```bash
# Simulace stisku dvou tlačítek, pouze vypíše dekódování:
printf '12200123\n12200124\n' | ./sampler --box b --simulate --listen
# Přehrání zvuku pro simulované stisky:
printf '12200123\n' | ./sampler --box b --simulate
```

### Automatické spuštění (systemd)
```bash
sudo cp sampler.service /etc/systemd/system/
sudo cp sampler /usr/local/bin/sampler
sudo systemctl enable --now sampler
```
*Pro Box C upravte řádek `ExecStart=` ve spouštěcím souboru služby.*

---

## Hardware / BOM (Česky)
Kompletní požadavky na hardware a nákupní seznam naleznete v souboru [`HW.md`](HW.md). 
Systém běží na sestavě tří zařízení (vše Raspberry Pi 4, 8 GB). Box A je tracker s webkamerou, zatímco Boxy B/C jsou bezdrátové spouštěče samplů. Každý box má vlastní USB zvukovou kartu (AXAGON ADA-17), panelové audio výstupy a interní reproduktor se zesilovačem.
Kompletní schémata zapojení jsou k dispozici v [`docs/SCH.md`](docs/SCH.md).

---

## Řešení problémů

### Problémy s kamerou na Termuxu
Android neposkytuje přímý přístup k `/dev/video0`. OpenCV `VideoCapture(0)` vyžaduje buď USB webkameru přes OTG adaptér, nebo přesměrování z `termux-camera-photo` do virtuálního zařízení (experimentální).

### Konflikty mezi Termux Qt6 a OpenCV
Pokud se OpenCV nenainstaluje na Termuxu kvůli chybám v závislostech Qt6:
```bash
pkg upgrade -y && apt --fix-broken install -y && pkg install -y opencv
```
Pokud to selže, spusťte `build_termux.sh`, který sestaví OpenCV ze zdrojových kódů bez podpory Qt.

### Nastavení GUI na Termuxu (X11)
```bash
pkg install termux-x11
termux-x11 :0 &
export DISPLAY=:0
./tracker
```

### Chybějící knihovny (Linux)
- **-lraylib**: `pkg install -y x11-repo && pkg install -y raylib`
- **-lGL**: `pkg install -y mesa`

---

## Struktura projektu
- `main.c` — Zdrojový kód aplikace Tracker
- `sampler.c` — Zdrojový kód aplikace Sampler (EV1527 RF + SDL2_mixer + volitelně LCD)
- `Makefile` — Systém sestavení
- `mapa.csv.example` — Šablona pro mapování RF kódů na zvukové stopy
- `build_termux.sh` — Skript pro nastavení v prostředí Termux
- `sampler.service` — systemd služba pro automatický start Boxů B/C
- `docs/` — Schémata, manuály a generátory PDF
- `HW.md` / `nakup.txt` / `dostupnost.txt` — Seznam hardwaru a součástek (česky)

## Verze
0.5.0
