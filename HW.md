# HW požadavky — Tracker (3 boxy)

Základní dokument pro stavbu hardwaru trackeru jako třídílného hudebního nástroje.
Ověřeno na **Alza.cz** a **GM Electronic (gme.cz)** dne **10. 9. 2026**. Ceny se liší dodací lhůtou a aktuální skladovostí — „≈" znamená orientační cenu, ostatní je ověřená.
Kompletní schémata všech propojení: [`docs/SCH.md`](docs/SCH.md).

> **Jednotná platforma**: všechny tři boxy používají **stejný Raspberry Pi 4 Model B (8 GB)**.
> Každý box má **vlastní USB zvukovou kartu** (AXAGON ADA-17 AUDIGO) a **stereo výstup 3,5 mm na panelu** krabice.
> Každý box má **vlastní zesilovač + interní reproduktor** (CA-3110S + LS40N 40 mm).

---

## 1) Architektura a role boxů

- **Box A** — Hlavní jednotka, běží stávající software tracker (webkamera snímá stůl, koule ovládají hlasitost loopů přes SDL2_mixer). Raspberry Pi 4 + webkamera + USB zvukovka + jack 3,5 na panelu + zesilovač + reproduktor. Napájení: vlastní zdroj 15,3 W (5 m šňůra)
- **Box B** — Spouštěč samplerů, 10 bezdrátových tlačítek, SDL Mixer přehrává X samplů, reproduktor přímo v krabici, displej 16×2 se stavem mixu, indikace chodu + reset. Raspberry Pi 4 + audio + LCD + RF přijímač 433 MHz + jack 3,5 na panelu + zesilovač + reproduktor. Napájení: vlastní zdroj 15,3 W (5 m šňůra)
- **Box C** — Stejná role jako B (druhá sekce, dalších 10 tlačítek). Raspberry Pi 4 + audio + LCD + RF přijímač 433 MHz + jack 3,5 na panelu + zesilovač + reproduktor. Napájení: vlastní zdroj 15,3 W (5 m šňůra)
- **20× tlačítko** — Hotové bezdrátové tlačítko Solight 1L67T (433 MHz, EV1527/learning-code, baterie uvnitř). 10 ks spárováno s B, 10 ks s C

Komunikace: tlačítka → RF 433 MHz (ASK/OOK) → přijímač SRX882S v B/C (GPIO, knihovna RCSwitch) → SDL Mixer.
Synchronizace samplerů a trackeru mezi A a B/C: WiFi (2,4 GHz; sample lze rsyncovat z A).
Audio: každý box má USB zvukovou kartu (AXAGON ADA-17); stereo výstup 3,5 mm je vyveden jackem na panelu krabice. Každý box má interní reproduktor přes zesilovač CA-3110S (paralelně s panelovým jackem přes Y-rozdvojku).
Napájení: **každý box má vlastní oficiální zdroj RPi 15,3 W** (5 V se mezi boxy nerozvádí). Každý box se zapojuje do 230 V **samostatně** (paralelně) — všemi 5 m šňůrami JT003 do zásuvky/odbočky (viz kapitola 4).

---

## 2) Objednávkový list — Alza.cz (3× Pi 4 8 GB, karty, kabeláž, webkamera, USB zvukovky)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| Raspberry Pi 4 Model B 8 GB — **pro všechny 3 boxy (A, B, C)** | 3 | **4 629 Kč** | [hledání](https://www.alza.cz/search.htm?exps=raspberry+pi+4+8gb) |
| Krabička na Pi 4: **Inter-Tech ODS-721 (hliník)** — JOY-IT RB-Heatsink je na Alze vyprodaný/chybí | 3 | **≈259 Kč** | [hledání](https://www.alza.cz/search.htm?exps=inter-tech+ods-721) |
|   alt. JOY-IT Armor / pasivní RB-Heatsink | — | 299 / 88 Kč | [hledání](https://www.alza.cz/search.htm?exps=joy-it+armor) |
| Oficiální zdroj RPi 15,3 W / USB-C 5,1 V 3 A — **pro všechny 3 boxy** | 3 | od **251 Kč** (černý skladem) | [hledání](https://www.alza.cz/search.htm?exps=raspberry+pi+15.3w) |
| **Webkamera** Logitech C920 Full HD, box A | 1 | **1 599 Kč** | [hledání](https://www.alza.cz/search.htm?exps=logitech+c920) |
|   alt. C922 2 499 / C920s 2 299 / Brio 300 1 299 / Brio 100 749 Kč | — | viz vedle | [hledání](https://www.alza.cz/search.htm?exps=logitech+webkamera) |
| microSD 32 GB SanDisk Ultra Class 10 A1 UHS-I — **pro všechny 3 boxy** | 3 | **≈350 Kč** | [hledání](https://www.alza.cz/search.htm?exps=sandisk+ultra+32gb+a1+microsd) |
| **USB zvuková karta** AXAGON ADA-17 AUDIGO (USB-A → 3,5 mm jack, Hi-Res DAC) — **pro všechny 3 boxy** | 3 | **≈150 Kč** | [hledání](https://www.alza.cz/search.htm?exps=axagon+ada-17) |
| micro-HDMI → HDMI kabel PremiumCord 1,8 m (setup/konzole) | 1 | **109 Kč** | [hledání](https://www.alza.cz/search.htm?exps=micro+hdmi+hdmi+kabel) |
| Stativ na kameru: Apexel Mini Tripod | 1 | **189 Kč** (rozkládací 459) | [hledání](https://www.alza.cz/search.htm?exps=apexel+mini+tripod) |

**Alza mezisoučet ≈ 16 100 Kč** (3× Pi 4 8 GB, 3× ODS-721, 3× PSU, webkamera, 3× SD 32 GB, 3× USB zvukovka AXAGON, mikro-HDMI, stativ).

> Pi 4 má sám 3,5 mm jack, ale dle požadavku je ve **všech** boxech použitá sjednocená **USB zvuková karta AXAGON ADA-17**
> a stereo výstup 3,5 mm je vyveden **jackem na panelu** krabice (interní jack Pi se nepoužívá).

---

## 3) Objednávkový list — GME (gme.cz): elektroboxy, šňůry, kabeláže, elektronika, RF tlačítka, jacky

### 3.1 Elektroboxy (3 ks)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| MASZCZYK KM-85 ABS černá, 180×160×84 mm, 4dílná | 3 | **209 Kč** /ks | [product](https://www.gme.cz/v/1508143/maszczyk-km-85-abs-black-krabicka-plastova) |

**Krabice celkem ≈ 630 Kč**.

### 3.2 Napájecí šňůry, kabeláž a elektro drobnosti

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| Napájecí flexo JT003 H05VV-F 3×1,5 mm², černá, **5 m** (3 ks) | 3 | **175 Kč**/ks | [product](https://www.gme.cz/v/1509985/jt003-h05vv-f-3x15-cerna-5m-napajeci-sitovy-kabel-flexo) |
| Montážní vodič Lanko CYA 1×0,5 mm² (H05V-K) — 3 m / barva: hnědá, modrá, žlutá | 3×3 m | **3,50 Kč/m** | [hnědá](https://www.gme.cz/v/1512384/elektrokabel-cya-1x05-hnedy-h05v-k-izolovany-vodic-lanko) / [modrá](https://www.gme.cz/v/1512208/elektrokabel-cya-1x05-modry-h05v-k-izolovany-vodic-lanko) / [žlutá](https://www.gme.cz/v/1511550/elektrokabel-cya-1x05-zluty-h05v-k-izolovany-vodic-lanko) |
| Svorkovnice KLS 301-5.00-02P 2pól 5 mm (přípojky 230 V) | 3 | **5 Kč**/ks | [product](https://www.gme.cz/v/1497538/kls-301-500-02p-2-sc-svorkovnice-2pol-roztec-5mm-16a-250v-vstup-90-sroub) |
| Distanční sloupek M2,5 × 10 mm, matka/šroub (montáž Pi 4) | 12 | **5,50 Kč**/ks | [product](https://www.gme.cz/v/1482591/da5m25x10-nikl-distancni-sloupek-10mm-m25-matka-sroub) |
| Sada smršťovacích bužírek KSS VS-100BK | 1 | **135 Kč** | [product](https://www.gme.cz/v/1483738/kss-vs-100bk-sada-smrstovacich-buzirek) |
| Tavící pistole Pro'sKit GK-390NF (11 mm, 100 W) | 1 | **≈200 Kč** | [product](https://www.gme.cz/v/1517598/proskit-gk-390nf-tavna-lepici-pistole-11mm-100w) |

### 3.3 Stereo výstupy na panelech a interní reproduktory (3 ks — všechny boxy)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| **Jack 3,5 mm stereo, zásuvka do panelu, EY-512C** — výstup na čelní stěně každé krabice | 3 | **15 Kč**/ks | [product](https://www.gme.cz/v/1496892/ey-512c-jack-35-stereo) |
| **Koncovka Jack 3,5 stereo, NP-107** — pro propojení kabeláže | 3 | **≈10 Kč**/ks | [product](https://www.gme.cz/v/1501905/np-107-en-jack-35-stereo) |
| **Zesilovač CREATALL CA-3110S** (TPA3110, třída D, stereo, napájení 8–26 V) — interní reproduktor | 3 | **49 Kč**/ks | [product](https://www.gme.cz/v/1518915/creatall-ca-3110s-digitalni-zesilovac-tridy-d-s-cipem-tp3110-napajeni-826v-3a) |
| **Reproduktor LS40N-27-R8** (40 mm, 8 Ω) — interní reproduktor | 6 | **62 Kč**/ks | [product](https://www.gme.cz/v/1497252/ls40n-27-r8-reproduktor) |

### 3.4 Bezdrátová tlačítka (20 ks) — hotová, 433 MHz

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| **Solight 1L67T** bezdrátové tlačítko pro zvonek 1L67 (433 MHz, learning-code, 200 m, baterie uvnitř) | 20 | **72,60 Kč** (VÝPRODEJ) | [GME](https://www.gme.cz/vysledky-vyhledavani?q=Solight+1L67T) |
| Náhradní baterie Camelion CR2032 BP5 (5 ks) | 6 | **19 Kč**/blistr | [product](https://www.gme.cz/v/1519272/camelion-cr2032-bp5-lithiova-knoflikova-baterie-blistr-5ks) |

**Tlačítka celkem ≈ 1 450 Kč (+ 114 Kč náhradní baterie).**
> ⚠ **VÝPRODEJ** — dostupné jen na 2 prodejnách — **objednat co nejdříve!**

### 3.5 RF přijímač 433 MHz (jen B a C)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| **SRX882S** přijímač 433 MHz ASK/FSK | 2 | **79 Kč**/ks | [product](https://www.gme.cz/v/1514654/srx882s-prijimac-433mhz-ask) |

### 3.6 Indikační panel a ovládání (3 ks — všechny boxy)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| **Tlačítko do panelu** PBS-12B-R (OFF/ON, 1 pol) | 3 | **≈15 Kč**/ks | [product](https://www.gme.cz/v/1497195/pbs-12b-r-tlacitko-do-panelu-1-pol-offon) |
| **LED dioda 5 mm červená** — indikace chodu | 10 | **≈2 Kč**/ks | [product](https://www.gme.cz/v/1492965/bright-led-bl-b5141-l-led-3mm-cervena) |
| **Rezistor 10 kΩ 0,25 W** (pull-up pro tlačítka) | 3 | **≈0,50 Kč**/ks | [product](https://www.gme.cz/v/1494150/gym-cym-rm-10k-06w-1-0207-metalizovany-rezistor) |
| **Rezistor 330 Ω 0,25 W** (pro LED) | 6 | **≈0,50 Kč**/ks | [product](https://www.gme.cz/v/1494150/gym-cym-rm-10k-06w-1-0207-metalizovany-rezistor) |

### 3.7 Celkový přehled GME

**GME mezisoučet ≈ 6 500 Kč** (3× KM-85, 3× flexo 5m, CYA dráty, svorkovnice, sloupky, bužírky, tavicí pistole, 3× jack panel, 3× jack koncovka, 3× zesilovač, 6× reproduktor, 2× RF RX, 20 tlačítek, baterie, LED, rezistory).

---

## 4) Napájení a rozvod (předpoklad)

- **230 V**: flexo JT003 H05VV-F 3×1,5 — **3× 5 m** (každý box svou šňůrou do zásuvky/odbočky).
- **Každý box se zapojuje do 230 V samostatně** (paralelně, ne do série) — vlastní 5 m šňůrou do zásuvky/odbočky.
- **Každý box má vlastní** oficiální zdroj RPi 15,3 W (USB-C 5,1 V / 3 A) — Pi 4 bere až 3 A, takže rozvod 5 V už nemá smysl.
- Uvnitř boxů vše na svorkovnice/lanko (žádné holé kabely v blízkosti hran krabice), gumové průchodky na vývody.
- **Reset tlačítko + indikace chodu**: dedikovaný GPIO pin → čistý shutdown/restart (systemd), power-LED na GPIO s rezistorem 330 Ω.

---

## 5) Schémata zapojení (GPIO, audio, RF 433 MHz)

> **Kompletní schémata všech propojení (box A, B, C, jacky, tlačítka, rozvod): [`docs/SCH.md`](docs/SCH.md)**

### 5.1 Dvouřádkový displej 16×2 (I2C, PCF8574) na GPIO Pi 4 (jen B a C)

| Pi GPIO (pin) | LCD modul | Poznámka |
|---------------|-----------|----------|
| 3V3 (pin 1) | VCC | viz napájení níže |
| GND (pin 6) | GND | |
| GPIO 2 / SDA (pin 3) | SDA | |
| GPIO 3 / SCL (pin 5) | SCL | |

- Modul (LCD + I2C adapter) je stavěn na **5 V**. **Bezpečné zapojení na GPIO:**
  - buď napájet VCC jen **3,3 V** (HD44780 reálně funguje, kontrast upravit potenciometrem), *nebo*
  - přidat **level shifter 3,3→5 V** na SDA/SCL a napájet modul 5 V z pinu 2/4.
- Adresa: **0x27** (někdy 0x3F) — `i2cdetect -y 1`; aktivace `dtparam=i2c_arm=on`.

### 5.2 Reset tlačítko + indikace chodu (stejné pro A, B a C)

```
Pi GPIO17 (pin 11) ──┬── TLAČÍTKO (NO) ── GND
                     └── 10 kΩ pull-up ── 3V3      (software: debounce)
Pi GPIO26 (pin 37) ──┬── 330 Ω ── LED [+] ── GND   (indikace chodu)
```

### 5.3 Zvukový výstup (USB zvukovka AXAGON ADA-17 → panelový stereo jack) — ve všech boxech

```
USB zvuková karta AXAGON ADA-17 (USB-A na Pi)     B/C (stejné pro všechny boxy):
  [stereo výstup 3,5 mm] ──► [Y-rozdvojka] ──► jack EY-512C do panelu
       │                                          └─► CA-3110S vstup → LS40N
       └──► JACK 3,5 stereo do panelu (EY-512C)            (interní reproduktor)
            TIP = L,  RING = R,  SLEEVE = GND
```
- Použít **vždy USB zvukovku AXAGON ADA-17**, ne interní jack Pi (interní jack se nezapojuje).
- Y-rozdvojka umožní paralelně: panelový výstup (na mix/pódiový zesilovač) **a** interní reproduktor.

### 5.4 RF přijímač 433 MHz (SRX882S) na GPIO Pi 4 (jen B a C)

```
Pi GPIO22 (pin 15) ◄── DATA ── SRX882S [VCC ◄── 3V3 (pin 1)]
Pi GND (pin 6)     ◄────── GND ── SRX882S [ANT ── integrovaná anténa]
```
- SRX882S (ASK/OOK, 433,92 MHz): DATA = 3,3 V logika, napájet **3V3**.
- Dekódování: `rc-switch`/`433Utils` na GPIO 22. Mapa `kód → sample` (10 → B, 10 → C). Hlásit dosah se zavřeným víkem.

---

## 6) Kalkulace práce (instalace)

Sazba **350 Kč/h**, ideální délka instalace **2 týdny**.

| Varianta | Hodin | Práce |
|---|---|---|
| 2 týdny × 6 h/den (10 prac. dní) | 60 h | 21 000 Kč |
| **2 týdny × 8 h/den (doporučeno / ideál)** | **80 h** | **28 000 Kč** |
| 2 týdny × 8 h včetně víkendů | 112 h | 39 200 Kč |

---

## 7) Odhad finální ceny (upraveno 10. 9. 2026 — 3× Pi 4 8 GB + AXAGON + 3× amp/repro)

| Sestava | HW | Doprava (~2 e-shopy) | Práce | Rezerva 10 % | **Celkem** |
|---|---|---|---|---|---|
| **Minimální** (C920, 60 h) | ≈25 500 | ≈500 | 21 000 | ≈2 700 | **≈49 700 Kč** |
| **Doporučená** (C920, 80 h) | ≈25 500 | ≈500 | 28 000 | ≈2 850 | **≈56 850 Kč** |
| **Komfort** (C920, 112 h) | ≈25 500 | ≈500 | 39 200 | ≈2 970 | **≈68 170 Kč** |

*Pozn.: HW vč. 3× Pi 4 (8 GB), 3× ODS-721, 3× zdroj 15,3 W, 3× USB zvukovka AXAGON ADA-17,
3× panelový jack, 3× zesilovač CA-3110S, 6× reproduktor LS40N, 2× RF RX, 20 hotových tlačítek,
5 m šňůry, kabeláže a drobností. Stativ a webkamera (C920) = Alza.*

---

## 8) Montážní checklist (RF 433 MHz, USB zvukovky, panelové jacky)

1. Zapájení kabeláže do svorkovnic v boxech; všechny boxy zapojit 5 m šňůrami JT003 do zásuvky/odbočky.
2. Osazení všech boxů: Pi 4 8 GB + ODS-721 + zdroj 15,3 W + USB zvukovka AXAGON ADA-17 + jack do panelu + zesilovač CA-3110S + reproduktor LS40N + kalibrace (README.md).
3. Box A: + webkamera na stativu. Boxy B/C: + LCD 16×2 na GPIO + SRX882S přijímač 433 MHz.
4. 20 hotových tlačítek: dekódování kódu (RCSwitch), mapa kód → sample (10 → B, 10 → C).
5. Instalace OS (Raspberry Pi OS Lite), ovladače (opencv, raylib, SDL2_mixer, librc-switch, i2c-tools), služby (reset, zobrazení mixu, zvukový výstup přes USB zvukovku).
6. Test synchronizace A↔B↔C (WiFi), RF dosahu (433 MHz), audio výstupů na panelech (stereo jacky), zátěžový 2denní test.

---

## 9) Předpoklady / otevřené volby

- **Všechny boxy = Raspberry Pi 4 8 GB** (rozhodnuto) — jednotnost HW, dost USB pro webkameru + zvukovku, GPIO totožné s Pi Zero.
- **Audio: ve všech boxech USB zvuková karta AXAGON ADA-17 + stereo jack 3,5 mm na panelu** (rozhodnuto); interní jack Pi 4 se nepoužívá. Interní reproduktor/zesilovač (CA-3110S + LS40N) je ve **všech** boxech.
- **RF: 433 MHz**, hotová tlačítka (Solight 1L67T + SRX882S); mimo WiFi pásmo; jednosměrné protokoly bez potvrzení.
- **Displej**: 16×2 I2C; alternativa malý OLED 0,91–1,3" (SSD1306).
- **Reset**: GPIO soft (shutdown); alternativa mechanický vypínač 230 V.
- Ceny ověřeny 10. 9. 2026; Solight 1L67T je **výprodej** — objednat co nejdříve; Pi 4 8 GB/ODS-721/zdroje běžně skladem.