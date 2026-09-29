# Schémata zapojení — Tracker (všechna propojení)

Dokument navazuje na [`HW.md`](../HW.md). Pokrývá **všechna elektrická propojení** sestavy:
box A (hlavní), box B (samplerový spouštěč), 10 bezdrátových tlačítek (433 MHz, hotová)
a rozvod napájení. GPIO čísla jsou **BCM**, v závorce číslo pinu 40pin konektoru.

Verze: 23. 9. 2026 — **oba boxy Raspberry Pi 4 8 GB (stejný model)**, každý box má
**USB zvukovou kartu AXAGON ADA-17** a **stereo jack 3,5 mm na panelu** krabice.
Každý box má **zesilovač CA-3110S + reproduktor LS40N** (interní reproduktor).

---

## 1) Blokové schéma systému

- **Box A** (hlavní jednotka) — Pi 4, USB zvukovka AXAGON ADA-17 → jack 3,5 na panelu + zesilovač CA-3110S → reproduktor LS40N, GPIO: reset/LED, webkamera USB (stativ, analýza koulí), HDMI (konzole/setup). Napájení: vlastní zdroj 15,3 W (5 m šňůra 230 V)
- **Box B** (sampler) — Pi 4, SRX882S 433 MHz, LCD 16×2 (volitelný), amp + repro LS40N, USB zvukovka AXAGON ADA-17 → Y-rozdvojka → jack 3,5 panel + CA-3110S. Napájení: vlastní zdroj 15,3 W (230 V samostatnou 5 m šňůrou JT003 do zásuvky)

Bezdrátová tlačítka: 10× Solight 1L67T (baterie uvnitř) pro B — RF 433 MHz (ASK).

Oba boxy: Raspberry Pi 4 Model B 8 GB (stejný HW), každý s **vlastním zdrojem 15,3 W** (5 V se mezi boxy nerozvádí).
Synchronizace samplů A↔B: WiFi 2,4 GHz (rsync), mimo pásmo RF 433 MHz.

---

## 2) BOX A — hlavní jednotka (Pi 4)

### 2.1 Přípojka 230 V (box A)

```
  Síť 230 V ── flexo JT003 H05VV-F 3×1,5 (5 m)
              ──► kabelová průchodka boxu A
                  ▼
            svorkovnice KLS 2pól + PE
            ┌────────┐
   L  ──►  │ L (hnědý)│ ) ──► L ──► zásuvka/kabel zdroje 15,3 W (box A)
            │        │
   N  ──►  │ N (modrý)│ ) ──► N ──► zásuvka/kabel zdroje 15,3 W (box A)
            │        │
   PE ──►  │ PE (z/ž)│ ) ──► PE (uzemnění) ─► připraveno pro kovovou
            └────────┘                          ochranu / štít kabelů
```
- Žluto-zelený vodič = PE; nikdy nepřerušovat spínačem.
- **Každý box se zapojuje do 230 V samostatně** (paralelně, ne do série): box A i box B každý svou vlastní 5 m šňůrou do zásuvky/odbočky.
- Délkové rezervy: ≥0,8 m uvnitř boxu (manipulace, dotažení svorek).

### 2.2 Napájení Pi 4

```
  230 V svorkovnice ──► oficiální zdroj RPi 15,3 W (USB-C, 5,1 V / 3 A)
                                 └► USB-C ─► Raspberry Pi 4 (power konektor)
```
- Každý box (A i B) má **vlastní** zdroj 15,3 W — 5 V se mezi boxy nerozvádí.

### 2.3 Periferie (USB / audio)

```
  Pi 4 (box A)
   ├─ USB-A ── webkamera (Logitech C920) ──► stativ nad hrací plochou
   ├─ USB-A ── USB zvuková karta AXAGON ADA-17 ─► stereo OUT ──► Y-rozdvojka
   │                                               ├► panelový jack EY-512C (stereo)
   │                                               └► CA-3110S → LS40N (interní repro)
   ├─ micro-HDMI ── HDMI kabel 1,8 m ──► (konzole / setup)
   └─ (interní 3,5 mm jack Pi 4 se NEPOUŽÍVÁ — audio vždy přes USB zvukovku AXAGON)
```

### 2.4 GPIO boxu A — reset + indikace chodu + tlačítko do panelu

```
  Pi 4 GPIO17 (pin 11) ──┬── TLAČÍTKO (NO) ── GND (pin 6)
                         └── 10 kΩ pull-up ── 3V3 (pin 1)
  Pi 4 GPIO26 (pin 37) ──┬── 330 Ω ── LED [+] ── GND (pin 9)
                         └── tlačítko do panelu (PBS-12B) ── GND
```
- Krátký stisk = `systemctl poweroff`, dvojitý stisk = restart (systémová služba).
- Pull-up může být i interní (`RPi.GPIO`/`/sys/class/gpio`), externí 10 kΩ je bezpečnější.

---

## 3) BOX B — samplerový spouštěč (Pi 4)

```
                ┌──────────────────────────────────────────────────┐
                │              Raspberry Pi 4 (8 GB)                │
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
                │  GPIO15 (pin 33) ◄── SRX882S  DATA               │
                │  3V3 (pin 1)    ◄──── SRX882S  CS  (jinak spí)    │
                │  GPIO37 (GPIO26) ── 330 Ω ─► LED [+] ─► GND         │
                │                                                    │
                │  USB-A ──► USB zvuková karta AXAGON ADA-17             │
                │  USB-A ──► (volné porty)                           │
                │  USB-C ──► zdroj 15,3 W (230 V samostatnou 5 m šňůrou)  │
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
              │ L=špička, R=kroužek, │ napájení 8–26 V  │
              │ G=plášť)  ──► výstup│  (VLASTNÍ zdroj!) │
              │   do mixu / ext. zesilovače └──────────────────┘
```
- **Panelový stereo výstup**: kontakt „špička" (TIP) = L, „kroužek" (RING) = R, „plášť" (SLEEVE) = GND.
- **Zesilovač — signál vs. napájení (dvě různé věci)**:
  - *Signál* jde z USB zvukovky přes Y-rozdvojku do vstupu CA-3110S; do jednoho
    vstupu se L/R sečtou přes stereo-mono rezistory, klasicky stačí levý kanál.
    Y-rozdvojka není zdroj napájení — je to jen rozdvojka dvou audio kanálů.
  - *Napájení* je vlastní: CA-3110S (TPA3110) potřebuje **8–26 V** (deska je
    dimenzovaná až na 3 A, ale pro 8 Ω repro stačí 12 V / 1 A — viz §5).
    **5 V z Pi na to nestačí a nesmí se to zkoušet** — chip má minimum 8 V.
  - Zesilovač tedy potřebuje vlastní zdroj, kromě dvou Pi zdrojů 15,3 W.
- **Zvuková karta**: výstup vzorků v ALSA (SDL2_mixer→ALSA→USB zvukovka); interní jack Pi se nepoužívá.
- **LCD**: adresa I2C 0x27 (průzkum `i2cdetect -y 1`); kontrast na trimru adaptéru;
  případně level shifter 3,3→5 V (napájení 5 V z pinu 2/4).
- **Anténa SRX882S**: integrovaná; modul držet ≥2 cm od Pi (rušení).

---

## 4) RF 433 MHz — tlačítka a přijímač

### 4.1 Zásilkový modul: Solight 1L67T (bezdrátové tlačítko)

```
  ┌────────────────────┐
  │  S O L I G H T 1L67T │   žádné zapojení — kompletní výrobek
  │  ██ TLAČÍTKO ██      │   baterie CR2032 uvnitř (vydrží ~1–2 roky)
  │  kryt na jmenovku     │   protokol: 433 MHz, learning-code (EV1527 kopie)
  └────────────────────┘   dosah: uvnitř 30–60 m, výrobně 200 m
```
- **Žádné pájení, žádný firmware.** Ukončení = stisk → krátký RF burst s unikátním kódem.
- Každé tlačítko označit jmenovkou (B01…B10) a pořadí vzorku.

### 4.2 Zásilkový modul: SRX882S (přijímač na Pi)

```
  SRX882S (433,92 MHz, ASK/OOK)
   ┌──────────┐
   │ [ANT]    │  integrovaná anténa (PCB)
   │ [VCC] ───► 3V3 (pin 1)
   │ [CS]  ───► 3V3 (pin 1)   ← povinné, jinak modul spí
   │ [DATA] ──► GPIO15 (pin 33)
   │ [GND] ───► GND (pin 6)
   └──────────┘    (pokud napájíte 5 V, DATA = 5 V logika → převodník!)
```
- **CS (pin 4) na 3V3.** Řídí režim modulu (`1 = pracuje, 0 = spánek`).
  Volně ponechaný nebo na GND znamená uspaný přijímač: DATA trvale nízká,
  na GPIO žádné hrany a tlačítko se tváří jako mrtvé — i s novou baterií a
  držené u antény. Před zapnutím přepoj a odpočítej piny: 1 ANT, 2 GND,
  3 VCC, **4 CS**, 5 DATA, 6 GND, 7 ANT.
- DATA je na **BCM 15 = fyzický pin 33**, ne GPIO 22 / pin 15 (předpis ty
  dvě čísla dřív zaměnil — jsou to dva různé piny).
- Dekódování: `sampler.c` (libgpiod, EV1527) na GPIO 15, přepínač
  `--rf-pin N` přepíše pin. Mapa `kód → sample` (10 ks → B). Hlásit dosah se
  zavřeným víkem.
- Tlačítko vysílá opakovaně, dokud je držené: při výchozím debounce 300 ms se
  jeden stisk vypíše až 16×. Pro režim hraní použij `--debounce-ms 5000`.

#### 4.2.1 Anténa — nejdřív bez pájení

Vlnová délka na 433,92 MHz: celá 69,1 cm, čtvrtvlnová **17,3 cm**, polovlnová 34,5 cm.

Box je **kovová krabice** a to je největší faktor, ne délka antény — tyč uvnitř
kovu často nehraje o nic víc. Pořadí, od nejlevnějšího:

1. **Odsadit modul od Pi o ≥2 cm** (stočeno v §3). Zdrojem rušení je CPU, USB
   zvukovka a zesilovač; to nevyřeší žádná anténa, jen lepší filtrace.
2. **Svisle** — tlačítka Solight mají anténu svislou, vodorovná přijímací tyč
   ztrácí na polarizaci.
3. **Náhradní tyč** — přiletovat ~17,3 cm drátu 1,5–2 mm (single core, ne
   stočit do těsné cívky — to posune rezonanci dolů).
4. **Zemina** — čtvrtvlnová tyč chce zemnicovou plochu; plocha PCB Pi je špatná
   a hlučná, malý samostatný kovový plíšek bývá lepší než lepší tyč.

Chceš-li opravdu dosah, vynést anténu **z krabice**: dipól 75 Ω na koaxu
(2× 34,5 cm) mimo kov. Jenže pak DATA na GPIO 15 nesmí být dlouhý kabel
vedený vedle spínacího zdroje — krátký koax nebo malý buffer, jinak si
line udělá vlastní anténu a bude jen chytit síť.

Pozor, ASK/OOK je modulovaný amplitudově s AGC: delší anténa zesílí všechno
včetně šumu. Pokud tlačítka začnou cvakat samy od sebe, znamení to je zkrácení
tyče nebo větší odstup, ne prodloužení.

Měřit na stole, ne odhadovat:
```bash
./sampler --box b --listen     # chodí se vzdalovat
```
opakovat se zavřenou krabicí. Rozdíl ukáže, jestli je anténa vůbec problém.

- **První nastavení**: každým tlačítkem stisknout a zapsat kód → soubor `mapa.csv`:

  ```
  # B box (Pi na adrese B): kód → sample
  12200123, sample_b_01.wav
  12200124, sample_b_02.wav
  ...
  ```
- Zpoždění odezvy: typicky 30–80 ms (burst), dostačující pro spouštění vzorků.

---

## 5) Napájení — každý box samostatně

Oba boxy jsou **stejné** (Pi 4) a napájení je jednotné — každý box se zapojuje do 230 V **samostatně** (paralelně), vlastní 5 m šňůrou JT003 do zásuvky/odbočky:

```
                    230 V zásuvka / odbočka
                            │
         ┌──────────────────┴──────────────────┐
         5 m JT003                             5 m JT003
         ▼                                     ▼
    ┌──────────┐                          ┌──────────┐
    │ BOX A    │                          │ BOX B    │
    │ vlastní  │                          │ vlastní  │
    │ PSU 15,3W│                          │ PSU 15,3W│
    └──────────┘                          └──────────┘
```
- Žádný rozvod 5 V mezi boxy — Pi 4 (až 3 A) má vždy svůj zdroj.
- **Boxy nejsou zapojeny do série** — každý má vlastní přípojku 230 V (vhodné jištění ≤10 A dle kabeláže).
- **Zesilovač potřebuje ještě třetí zdroj.** CA-3110S běží na 8–26 V, takže ho
  nelze napájet z 5 V Pi ani z 5 V USB zvukovky. Na 230 V se připojuje
  samostatným adaptérem dovnitř krabice, sdílenou zem se zemí Pi (aby nevznikla
  smyčka). Chybí v `nakup.txt` — doplnit.
- **Jak velký ten zdroj má být** (8 Ω repro, 12 V):

  | Proud zdroje | Výkon do 8 Ω | Poznámka |
  |---|---|---|
  | 250 mA | ~2,7 W | **nestací** — tlaci na peakách, chrčí |
  | 1 A | ~10 W | správně |
  | 2 A | ~21 W | rezerva, ale 12 V už je limit |

  12 V do 8 Ω dá ideálně max **~9 W** (omezení napětím, ne proudem), takže 1 A
  je správná volba a 2 A pro klid. Na 30 W z inzerátu se dostaneš až s 24 V.
  Trída D má vysoký crest faktor (peaky 3–10× RMS), proto poddimenzovaný zdroj
  chrčí na transienty, ne že by byl „tišší".
- Odběr boxu < 1,5 A u Pi 4 běžně; 3A zdroj dává rezervu pro USB zvukovku + kameru (A).

---

## 6) Souhrn použitých GPIO pinů (Raspberry Pi 4 8 GB)

| Funkce         | GPIO (BCM) | Pin | Zapojeno s |
|----------------|-----------|-----|------------|
| I2C SDA        | 2         | 3   | LCD 1602 (PCF8574) — jen B |
| I2C SCL        | 3         | 5   | LCD 1602 (PCF8574) — jen B |
| RF RX DATA     | 15        | 33  | SRX882S DATA — jen B |
| RF RX CS       | —         | —   | SRX882S CS → 3V3, jinak spí |
| Reset tlačítko | 17        | 11  | tlačítko NO → GND, pull-up 10 kΩ |
| Indikace chodu | 26        | 37  | 330 Ω → LED → GND |
| 3V3            | —         | 1   | SRX882S VCC, LCD VCC (3,3 V varianta), pull-upy |
| GND            | —         | 6   | SRX882S, LCD, tlačítko, LED (zesilovač má vlastní zdroj, zem společná) |

Pi 4 8 GB sdílé 40pin GPIO rozvržení a BCM číslování → schémata jsou přenositelná.
Box A: BCM **17** (reset) a **26** (LED) — stejná schémata jako §3/§6.
Webkamera, HDMI, audio (USB zvukovka AXAGON ADA-17 + panelový jack) — bez GPIO (USB báze).

---

## 7) Zvukové výstupy — panelové stereo jacky (oba boxy)

```
  USB zvuková karta AXAGON ADA-17 (každý box) ──► 3,5 mm stereo OUT
       │ Y-rozdvojka (všechny boxy)
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
- Box B: paralelně z Y-rozdvojky jde signál i do CA-3110S (interní reproduktor).

---

## 8) Montážní poznámky

1. FM rozvodem a lanky vedenými po prostoru boxu bez ostrých hran (bužírka, průchodky).
2. Svorkovnice utahovat momentem; doporučené barvy: L=černá/hnědá, N=modrá, PE=žluto-zelená, V+=červená, V−=černá.
3. LED/rezistor/cca: rezistor 330 Ω (3,3 V) → I ≈ 8–10 mA.
4. Spárování a mapa tlačítek před montáží do stolu; značení dolů na spodní straně.
5. Zátěžový test: RF dosah se zavřeným víkem boxu, výdrž baterie, kabeláž bez tepelných stop (termokamera).
6. **Audio:** každý box prozvukovat z USB zvukovky AXAGON ADA-17 (ne interní jack Pi) — levý/pravý kanál na panelovém jacku + interní reproduktor přes CA-3110S.