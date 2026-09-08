# Schémata zapojení — Tracker (všechna propojení)

Dokument navazuje na [`HW.md`](../HW.md). Pokrývá **všechna elektrická propojení** sestavy:
box A (hlavní), boxy B/C (samplerové spouštěče), 20 bezdrátových tlačítek (433 MHz, hotová)
a rozvod napájení. GPIO čísla jsou **BCM**, v závorce číslo pinu 40pin konektoru.

Verze: 8. 9. 2026 (architektura RF 433 MHz — tlačítka Solight 1L67T + přijímač SRX882S).

---

## 1) Blokové schéma systému

```
            230 V / 50 Hz  ──┐
                             ▼
                     ┌────────────────┐
        ┌───────────►│   BOX A (Pi 4) │◄──────── webkamera (USB) ── stativ
        │            │  rozvod + PSU  │            tracker (analýza koulí)
        │ 5 V lanko  │ 15,3 W USB-C   │─► 3,5 mm jack ── (volitelně) repro
        │ (0,75–1,5) └───────┬────────┘
        │                    │ rozvod 5 V (varianta a)
        ▼                    ▼
 ┌─────────────┐      ┌─────────────┐
 │  BOX B      │      │  BOX C      │      Pi Zero 2 WH + LCD + zesilovač + repro
 │  Pi Zero    │      │  Pi Zero    │      + USB zvukovka + RX 433 MHz (SRX882S)
 │  SRX882S ◄──┼──┐   │  SRX882S ◄──┼──┐
 └─────────────┘  │   └─────────────┘  │
                  │ RF 433 MHz (ASK)   │
                  ▼                    ▼
           10× tlačítko         10× tlačítko
           Solight 1L67T        Solight 1L67T
           (baterie uvnitř)     (baterie uvnitř)

   Synchronizace samplů A↔B↔C: WiFi 2,4 GHz (rsync), mimo pásmo RF 433 MHz.
```

---

## 2) BOX A — hlavní jednotka (Pi 4)

### 2.1 Přípojka 230 V a rozvod

```
  Síť 230 V ── 2× flexo JT003 H05VV-F 3×1,5 (celkem 10 m)
              ──► kabelová průchodka boxu A
                  ▼
            svorkovnice KLS 3pól (10 ks v sadě)
            ┌────────┐
   L  ──►  │ L (černý│ ) ──► L ──► zásuvka/kabel zdroje 15,3 W
            │        │
   N  ──►  │ N       │ ) ──► N ──► zásuvka/kabel zdroje 15,3 W
            │        │
   PE ──►  │ PE (z/ž)│ ) ──► PE (uzemnění) ─► připraveno pro kovovou
            └────────┘                          ochranu / štít kabelů
```
- Žluto-zelený vodič = PE; nikdy nepřerušovat spínačem.
- Délkové rezervy: ≥0,8 m uvnitř boxu (manipulace, dotažení svorek).

### 2.2 Napájení Pi 4

```
  230 V svorkovnice ──► oficiální zdroj RPi 15,3 W (USB-C, 5,1 V / 3 A)
                                └► USB-C ─► Raspberry Pi 4 (power konektor)
```

### 2.3 Periferie (USB / HAT / jack)

```
  Pi 4
   ├─ USB-A ── webkamera (Logitech C270 / C920) ──► stativ nad hrací plochou
   ├─ micro-HDMI ── HDMI kabel 1,8 m ──► (konzole / setup)
   ├─ 3,5 mm jack ── audio výstup trackeru (SDL2_mixer)  [volitelně repro]
   └─ USB-A ── (rozvod 5 V do B/C — varianta a, viz §6; jemný výstup nezatěžovat)
```

### 2.4 GPIO boxu A — reset + indikace chodu (BCM 17 a 26, jako v B/C)

```
  Pi 4 GPIO17 (pin 11) ──┬── TLAČÍTKO (NO) ── GND (pin 6)
                         └── 10 kΩ pull-up ── 3V3 (pin 1)
  Pi 4 GPIO26 (pin 37) ──┬── 330 Ω ── LED [+] ── GND (pin 9)
```
- Krátký stisk = `systemctl poweroff`, dvojitý stisk = restart (systémová služba).
- Pull-up může být i interní (`RPi.GPIO`/`/sys/class/gpio`), externí 10 kΩ je bezpečnější.

---

## 3) BOX B — samplerový spouštěč (Pi Zero 2 WH)

Kompletní zapojení jedné jednotky; box C je identický (§4).

```
               ┌──────────────────────────────────────────────────┐
               │                   Pi Zero 2 WH                    │
               │                                                    │
               │  GPIO 1 (3V3) ──┬────► LCD 1602  VCC (3,3 V varianta) │
               │                ├────► SRX882S  VCC                │
               │                └────► pull-upy 4,7 kΩ (SDA/SCL, volitelně)
               │  GPIO 3 (SDA) ───────► LCD 1602  SDA              │
               │  GPIO 5 (SCL) ───────► LCD 1602  SCL              │
               │  GPIO 6 (GND) ──┬────► LCD 1602  GND              │
               │                ├────► SRX882S  GND                │
               │                ├────► tlačítko reset              │
               │                └────► LED (–)                     │
               │  GPIO11 (GPIO17) ─┬── TLAČÍTKO reset (NO) ─► GND  │
               │                   └── 10 kΩ ─► 3V3                │
               │  GPIO15 (GPIO22) ◄──── SRX882S  DATA              │
               │  GPIO37 (GPIO26) ── 330 Ω ──► LED [+] ─► GND      │
               │                                                    │
               │  USB-A ──► USB zvuková karta (Gembird) ─ 3,5 mm ► │
               │  micro-USB ──► zdroj 5 V (varianta a/b, §6)       │
               └──────────────────────────────────────────────────┘
                        │ 3,5 mm OUT (levý kanál)
                        ▼
               ┌─────────────────┐
               │  CA-3110S zesilovač │──► reproduktor LS40N 40 mm, 8 Ω
               │  (TP3110, tr. D)   │          (L+/L─ na piny, mono)
               │  napájení 5–26 V   │
               └─────────────────┘
```
- **Zesilovač**: napájet z místního 5 V rozvodu (§6) — při hlasitosti vzorků na 40 mm reproductoru je výkon s rezervou; pro plný výkon CA-3110S použít samostatný zdroj 9–12 V (ne z Pi).
- **Zvuková karta**: Pi Zero nemá analogový jack → výstup vzorků jde z USB zvukovky (hlasitost v ALSA), po mono kanálu do zesilovače.
- **LCD**: adresa I2C 0x27 (průzkum `i2cdetect -y 1`); kontrast na trimru adaptéru; případně level shifter 3,3→5 V (napájení 5 V z pinu 2/4).
- **Anténa SRX882S**: integrovaná; modul držet ≥2 cm od Pi (rušení).

---

## 4) BOX C — identický s boxem B

Veškeré zapojení §3 platí beze změny (stejný seznam součástek).
Pouze **mapa tlačítek a nastavený obor vzorků je jiná** (C = sekce vzorků č. 11–20).

---

## 5) RF 433 MHz — tlačítka a přijímač

### 5.1 Zásilkový modul: Solight 1L67T (bezdrátové tlačítko)

```
  ┌────────────────────┐
  │  S O L I G H T 1L67T │   žádné zapojení — kompletní výrobek
  │  ██ TLAČÍTKO ██      │   baterie CR2032 uvnitř (vydrží ~1–2 roky)
  │  kryt na jmenovku     │   protokol: 433 MHz, learning-code (EV1527 kopie)
  └────────────────────┘   dosah: uvnitř 30–60 m, výrobně 200 m
```
- **Žádné pájení, žádný firmware.** Ukončení = stisk → krátký RF burst s unikátním kódem.
- Každé tlačítko označit jmenovkou (B01…B10 / C01…C10) a pořadí vzorku.

### 5.2 Zásilkový modul: SRX882S (přijímač na Pi)

```
  SRX882S (433,92 MHz, ASK/OOK)
   ┌──────────┐
   │ [ANT]    │  integrovaná anténa (PCB)
   │ [VCC] ───► 3V3 (pin 1)
   │ [DATA] ──► GPIO22 (pin 15)
   │ [GND] ───► GND (pin 6)
   └──────────┘    (pokud napájíte 5 V, DATA = 5 V logika → převodník!)
```
- Dekódování: `rc-switch` (C: `RCSwitch rc; rc.enableReceive(22);`) nebo `433Utils`.
- **První nastavení**: každým tlačítkem stisknout a zapsat kód → soubor `mapa.csv`:

  ```
  # B box (Pi na adrese B): kód → sample
  12200123, sample_b_01.wav
  12200124, sample_b_02.wav
  ...
  ```
- Zpoždění odezvy: typicky 30–80 ms (burst), dostačující pro spouštění vzorků.

---

## 6) Napájení B/C — dvě varianty rozvodu

### 6a) Varianta „5 V lanko z A" (doporučeno)

```
  BOX A                               BOX B / C
  USB-A / malý 5 V zdroj (3 A)        ┌──────────────────┐
   V+  ── 0,75–1,5 mm² (např. červená)──► V+ ── mikro-USB/Pi 5V │
   V−  ── (černá/modrá)             ──► V− ── GND            │
   (svorkovnice v A)  ≤1,5 m lanko   └──────────────────┘
```
- Odběr boxu < 1,5 A → úbytek na 1,5 m × 1,5 mm² ≈ 0,1 V (vyhoví).
- V A dát pojistku/self-healing PTC 2 A na vývod (ochrana rozvodu).

### 6b) Varianta „vlastní adaptér"

```
  BOX A                            BOX B/C
  krátká síťová šňůra 2 m ──► malý 5 V mikro-USB zdroj ──► Pi Zero
```
- Jednoduché, izolované; cena navíc ≈ 150–250 Kč na box.

---

## 7) Souhrn použitých GPIO pinů (Pi Zero v B/C)

| Funkce         | GPIO (BCM) | Pin | Zapojeno s |
|----------------|-----------|-----|------------|
| I2C SDA        | 2         | 3   | LCD 1602 (PCF8574) |
| I2C SCL        | 3         | 5   | LCD 1602 (PCF8574) |
| RF RX DATA     | 22        | 15  | SRX882S DATA |
| Reset tlačítko | 17        | 11  | tlačítko NO → GND, pull-up 10 kΩ |
| Indikace chodu | 26        | 37  | 330 Ω → LED → GND |
| 3V3            | —         | 1   | SRX882S VCC, LCD VCC (3,3 V varianta), pull-upy |
| GND            | —         | 6   | SRX882S, LCD, tlačítko, LED, zesilovač (společná zem) |

Box A: BCM **17** (reset) a **26** (LED) — stejná schémata jako §3/§7.
Webkamera, HDMI, zvukový jack, USB zvukovka — bez GPIO (USB/video báze).

---

## 8) Montážní poznámky

1. FM rozvodem a lanky vedenými po prostoru boxu bez ostrých hran (bužírka, průchodky).
2. Svorkovnice utahovat momentem; doporučené barvy: L=černá/hnědá, N=modrá, PE=žluto-zelená, V+=červená, V−=černá.
3. LED/rezistor/cca: rezistor 330 Ω (3,3 V) → I ≈ 8–10 mA.
4. Spárování a mapa tlačítek před montáží do stolu; značení dolů na spodní straně.
5. Zátěžový test: RF dosah se zavřeným víkem boxu, výdrž baterie, kabeláž bez tepelných stop (termokamera).