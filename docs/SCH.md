# Schémata zapojení — Tracker (všechna propojení)

Dokument navazuje na [`HW.md`](../HW.md). Pokrývá **všechna elektrická propojení** sestavy:
box A (hlavní), boxy B/C (samplerové spouštěče), 20 bezdrátových tlačítek (433 MHz, hotová)
a rozvod napájení. GPIO čísla jsou **BCM**, v závorce číslo pinu 40pin konektoru.

Verze: 9. 9. 2026 — **všechny boxy Raspberry Pi 4 (stejný model)**, každý box má
**USB zvukovou kartu** a **stereo jack 3,5 mm na panelu** krabice.

---

## 1) Blokové schéma systému

```
            230 V / 50 Hz ── 10 m flexo JT003 (2× 5 m) ──┐
                                                         ▼
                                              ┌───────────────────┐
                         ┌────────────────────►│   BOX A (Pi 4)    │◄──── webkamera (USB) ── stativ
                         │  krátká smyčka běhu │  rozvod 230 V +   │      tracker (analýza koulí)
                         │  (uvnitř A)         │  PSU 15,3 W       │
                         │                     │  USB zvukovka ─► jack 3,5 na panelu
                         │                     │  GPIO: reset/LED  │
                         │                     └───────┬───────────┘
                         │ krátké síťové šňůry 2 m      │
                         ▼                              │
              ┌───────────────────┐                     │
              │    BOX B (Pi 4)   │◄────────────────────┘
              │  SRX882S 433 MHz  │        (230 V smyčka z A → vlastní PSU)
              │  LCD 16×2 + amp + │       (krátká 2 m šňůra JT003)
              │  repro LS40N      │
              │  USB zvukovka ─► Y-rozdvojka ─► jack 3,5 panel + CA-3110S
              └─────────┬─────────┘
                        │ RF 433 MHz (ASK)
                        ▼
                 10× tlačítko Solight 1L67T (baterie uvnitř)

   BOX C — identický s boxem B (dalších 10× tlačítko, samostatná 2 m šňůra z A).

   Všechny tři boxy: Raspberry Pi 4 Model B 4 GB (stejný HW).
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
   L  ──►  │ L (černý)│ ) ──► L ──► zásuvka/kabel zdroje 15,3 W (box A)
            │        │
   N  ──►  │ N       │ ) ──► N ──► zásuvka/kabel zdroje 15,3 W (box A)
            │        │
   PE ──►  │ PE (z/ž)│ ) ──► PE (uzemnění) ─► připraveno pro kovovou
            └────────┘                          ochranu / štít kabelů
```
- Žluto-zelený vodič = PE; nikdy nepřerušovat spínačem.
- Ze svorkovnice A jdou **dvě krátké 2 m šňůry JT003** ven k boxům B a C (230 V).
- Délkové rezervy: ≥0,8 m uvnitř boxu (manipulace, dotažení svorek).

### 2.2 Napájení Pi 4

```
  230 V svorkovnice ──► oficiální zdroj RPi 15,3 W (USB-C, 5,1 V / 3 A)
                                 └► USB-C ─► Raspberry Pi 4 (power konektor)
```
- Každý box (A, B i C) má **vlastní** zdroj 15,3 W — 5 V se mezi boxy nerozvádí.

### 2.3 Periferie (USB / audio)

```
  Pi 4 (box A)
   ├─ USB-A ── webkamera (Logitech C270 / C920) ──► stativ nad hrací plochou
   ├─ USB-A ── USB zvuková karta (Gembird) ─► stereo OUT ──► panelový jack EY-512C
   ├─ micro-HDMI ── HDMI kabel 1,8 m ──► (konzole / setup)
   └─ (interní 3,5 mm jack Pi 4 se NEPOUŽÍVÁ — audio vždy přes USB zvukovku)
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

## 3) BOX B — samplerový spouštěč (Pi 4)

Kompletní zapojení jedné jednotky; box C je identický (§4).

```
                ┌──────────────────────────────────────────────────┐
                │              Raspberry Pi 4 (4 GB)                │
                │                                                    │
                │  GPIO 1 (3V3) ──┬──► LCD 1602  VCC (3,3 V varianta)│
                │                ├──► SRX882S  VCC                   │
                │                └──► pull-upy 4,7 kΩ (SDA/SCL)      │
                │  GPIO 3 (SDA) ──────► LCD 1602  SDA                │
                │  GPIO 5 (SCL) ──────► LCD 1602  SCL                │
                │  GPIO 6 (GND) ──┬──► LCD 1602  GND                 │
                │                 ├──► SRX882S  GND                   │
                │                 ├──► tlačítko reset                 │
                │                 └──► LED (–)                        │
                │  GPIO11 (GPIO17) ─┬─ TLAČÍTKO reset (NO) ─► GND     │
                │                   └─ 10 kΩ ─► 3V3                   │
                │  GPIO15 (GPIO22) ◄──── SRX882S  DATA                │
                │  GPIO37 (GPIO26) ── 330 Ω ─► LED [+] ─► GND         │
                │                                                    │
                │  USB-A ──► USB zvuková karta (Gembird)             │
                │  USB-A ──► (volné porty)                           │
                │  USB-C ──► zdroj 15,3 W (230 V z A, 2 m šňůra)     │
                └───────────────┬────────────────────────────────────┘
                                │ 3,5 mm stereo OUT (USB zvukovka)
                                ▼
                    ┌─────────────────────────┐
                    │ Y-rozdvojka PremiumCord │  JACK 3,5 M → 2× JACK 3,5 F
                    └───────┬─────────┬───────┘
                            │         │
              ┌─────────────▼──┐  ┌───▼──────────────┐
              │ panelový jack  │  │ CA-3110S zesilovač│──► LS40N 40 mm, 8 Ω
              │ EY-512C (stereo│  │ (TP3110, tr. D)   │       (interní repro)
              │ L=špička, R=kroužek, │ napájení 5–26 V  │
              │ G=plášť)  ──► výstup│                  │
              │   do mixu / ext. zesilovače └──────────────────┘
```
- **Panelový stereo výstup**: kontakt „špička" (TIP) = L, „kroužek" (RING) = R, „plášť" (SLEEVE) = GND.
- **Zesilovač**: napájet z 5 V rozvodu boxu (výstup USB zvukovky → Y-rozdvojka → CA-3110S);
  jeden kanál přes stereo-mono rezistory (L/R do jednoho vstupu), klasicky levý kanál stačí.
- **Zvuková karta**: výstup vzorků v ALSA (SDL2_mixer→ALSA→USB zvukovka); interní jack Pi se nepoužívá.
- **LCD**: adresa I2C 0x27 (průzkum `i2cdetect -y 1`); kontrast na trimru adaptéru;
  případně level shifter 3,3→5 V (napájení 5 V z pinu 2/4).
- **Anténa SRX882S**: integrovaná; modul držet ≥2 cm od Pi (rušení).

---

## 4) BOX C — identický s boxem B

Veškeré zapojení §3 platí beze změny (stejný seznam součástek, stejný Raspberry Pi 4).
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

## 6) Napájení — jeden jednotný rozvod

Všechny tři boxy jsou **stejné** (Pi 4) a napájení je jednotné:

```
  BOX A                  BOX B                   BOX C
  ┌──────────┐    2 m   ┌──────────┐     2 m    ┌──────────┐
  │ svorkov. ├─────────►│ vlastní  │◄──────────┤ svorkov. │
  │ 230 V    │ šňůra    │ PSU 15,3W│  šňůra    │ (z A)    │
  │ 15,3 W   │ JT003    │ (Pi 4)   │  JT003    │ 15,3 W   │
  └──────────┘          └──────────┘           └──────────┘
```
- Žádný rozvod 5 V mezi boxy — Pi 4 (až 3 A) má vždy svůj zdroj.
- V boxu A dát na oba „odbočkové" vývody jističku resp. vhodné jištění 230 V (≤10 A).
- Odběr boxu < 1,5 A u Pi 4 běžně; 3A zdroj dává rezervu pro USB zvukovku + kameru (A).

---

## 7) Souhrn použitých GPIO pinů (Raspberry Pi 4 — stejné pro všechny boxy)

| Funkce         | GPIO (BCM) | Pin | Zapojeno s |
|----------------|-----------|-----|------------|
| I2C SDA        | 2         | 3   | LCD 1602 (PCF8574) — jen B/C |
| I2C SCL        | 3         | 5   | LCD 1602 (PCF8574) — jen B/C |
| RF RX DATA     | 22        | 15  | SRX882S DATA — jen B/C |
| Reset tlačítko | 17        | 11  | tlačítko NO → GND, pull-up 10 kΩ |
| Indikace chodu | 26        | 37  | 330 Ω → LED → GND |
| 3V3            | —         | 1   | SRX882S VCC, LCD VCC (3,3 V varianta), pull-upy |
| GND            | —         | 6   | SRX882S, LCD, tlačítko, LED, zesilovač (společná zem) |

Pi 4 i Pi Zero sdílí stejné 40pin GPIO rozvržení a BCM číslování → schémata jsou přenositelná.
Box A: BCM **17** (reset) a **26** (LED) — stejná schémata jako §3/§7.
Webkamera, HDMI, audio (USB zvukovka + panelový jack) — bez GPIO (USB báze).

---

## 8) Zvukové výstupy — panelové stereo jacky (všechny boxy)

```
  USB zvuková karta (každý box) ──► 3,5 mm stereo OUT
       │ box A: přímo
       │ boxy B/C: Y-rozdvojka PremiumCord
       ▼
  Panelový jack EY-512C (zásuvka do panelu, montáž na čelní stěnu krabice)
    ┌────────────────────────────┐
    │  TIP (špička)  = L  ▼      │
    │  RING (kroužek)= R         │
    │  SLEEVE (plášť)= GND       │
    └────────────────────────────┘
        └─► stereo kabel → mixážní pult / pódiový zesilovač / DL
```
- Montáž: vyvrtat otvor Ø6 mm do čelní stěny krabice, jack přitáhnout maticí (motýlek).
- Boxy B/C: paralelně z Y-rozdvojky jde signál i do CA-3110S (interní reproduktor).

---

## 9) Montážní poznámky

1. FM rozvodem a lanky vedenými po prostoru boxu bez ostrých hran (bužírka, průchodky).
2. Svorkovnice utahovat momentem; doporučené barvy: L=černá/hnědá, N=modrá, PE=žluto-zelená, V+=červená, V−=černá.
3. LED/rezistor/cca: rezistor 330 Ω (3,3 V) → I ≈ 8–10 mA.
4. Spárování a mapa tlačítek před montáží do stolu; značení dolů na spodní straně.
5. Zátěžový test: RF dosah se zavřeným víkem boxu, výdrž baterie, kabeláž bez tepelných stop (termokamera).
6. **Audio:** každý box prozvukovat z USB zvukovky (ne interní jack Pi) — levý/pravý kanál na panelovém jacku.