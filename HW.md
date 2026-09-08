# HW požadavky — Tracker (3 boxy)

Základní dokument pro stavbu hardwaru trackeru jako třídílného hudebního nástroje.
Ověřeno na **Alza.cz** a **GM Electronic (gme.cz)** dne **9. 9. 2026**. Ceny se liší dodací lhůtou a aktuální skladovostí — „≈" znamená orientační cenu, ostatní je ověřená.
Kompletní schémata všech propojení: [`docs/SCH.md`](docs/SCH.md).

> **Jednotná platforma**: všechny tři boxy používají **stejný Raspberry Pi 4 Model B (4 GB)**.
> Každý box má **vlastní USB zvukovou kartu** a **stereo výstup 3,5 mm na panelu** krabice.

---

## 1) Architektura a role boxů

| Box | Role | HW |
|-----|------|----|
| **A** | Hlavní jednotka — běží stávající software **tracker** (webkamera snímá stůl, koule ovládají hlasitost loopů přes SDL2_mixer). Rozvod sítě pro celou sestavu. | **Raspberry Pi 4** + webkamera + USB zvukovka + jack 3,5 na panelu |
| **B** | **Spouštěč samplerů** — 10 bezdrátových tlačítek, SDL Mixer přehrává X samplů, malý reproduktor přímo v krabici, displej 16×2 se stavem mixu, indikace chodu + reset | **Raspberry Pi 4** + audio + LCD + RF přijímač 433 MHz + jack 3,5 na panelu |
| **C** | Stejná role jako B (druhá sekce, dalších 10 tlačítek) | **Raspberry Pi 4** + audio + LCD + RF přijímač 433 MHz + jack 3,5 na panelu |
| **20× tlačítko** | **Hotové bezdrátové tlačítko** Solight 1L67T (433 MHz, EV1527/learning-code, baterie uvnitř) | 10 ks spárováno s B, 10 ks s C |

Komunikace: tlačítka → RF **433 MHz** (ASK/OOK) → přijímač **SRX882S** v B/C (GPIO, knihovna RCSwitch) → SDL Mixer.
Synchronizace samplerů a trackeru mezi A a B/C: WiFi (2,4 GHz; sample lze rsyncovat z A).
Audio: každý box má **USB zvukovou kartu**; stereo výstup 3,5 mm je vyveden **jackem na panelu** krabice (boxy B/C ho sdílejí i s interním zesilovačem k reproduktoru).
Napájení: 230 V přivedeno **10 m šňůrou do elektroboxu A**; každý box má vlastní oficiální zdroj RPi 15,3 W (USB-C) — do B a C jde krátká síťová šňůra (viz kapitola 4).

```
        [20× hotové tlačítko Solight 1L67T ─ cca 10/B, 10/C]
                        │ RF 433 MHz (ASK)
         ┌──────────────┼──────────────┐
         ▼              ▼              ▼
      [Box B]        [Box C]        [Box A]
      Pi 4 4 GB     Pi 4 4 GB      Pi 4 4 GB + webkamera (tracker)
      SRX882S       SRX882S
      LCD 16×2      LCD 16×2        (USB zvukovka → jack 3,5 na panelu
      repro+amp     repro+amp        – stejně ve všech boxech)
      USB zvukovka  USB zvukovka
      jack 3,5      jack 3,5
         │              │              │  ← krátké síťové šňůry 2 m
         └──────┬───────┴──────┬───────┘
      rozvod v boxu A ◄─── 10 m šňůra H05VV-F 3×1,5 s koncovkou (230 V)
```

---

## 2) Objednávkový list — Alza.cz (3× Pi 4, karty, kabeláž, webkamera, stativ, USB zvukovky)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| Raspberry Pi 4 Model B 4 GB — **pro všechny 3 boxy (A, B, C)** | 3 | **3 029 Kč** | [hledání](https://www.alza.cz/search.htm?exps=raspberry+pi+4+4gb) |
| Krabička na Pi 4: **Inter-Tech ODS-721 (hliník)** — JOY-IT RB-Heatsink je na Alze vyprodaný/chybí | 3 | **≈259 Kč** | [hledání](https://www.alza.cz/search.htm?exps=inter-tech+ods-721) |
|   alt. JOY-IT Armor / pasivní RB-Heatsink | — | 299 / 88 Kč | [hledání](https://www.alza.cz/search.htm?exps=joy-it+armor) |
| Oficiální zdroj RPi 15,3 W / USB-C 5,1 V 3 A — **pro všechny 3 boxy** | 3 | od **251 Kč** (černý skladem) | [hledání](https://www.alza.cz/search.htm?exps=raspberry+pi+15.3w) |
| **Webkamera** Logitech C270 HD (rozpočet), box A | 1 | **599–799 Kč** | [hledání](https://www.alza.cz/search.htm?exps=logitech+c270) |
| **Webkamera** Logitech C920 Full HD (doporučeno), box A | 1 | **1 599 Kč** | [hledání](https://www.alza.cz/search.htm?exps=logitech+c920) |
|   alt. C922 2 499 / C920s 2 299 / Brio 300 1 299 / Brio 100 749 Kč | — | viz vedle | [hledání](https://www.alza.cz/search.htm?exps=logitech+webkamera) |
| microSD 64 GB SanDisk Ultra (rozpočet), box A | 1 | **549 Kč** | [hledání](https://www.alza.cz/search.htm?exps=sandisk+ultra+64gb+microsd) |
| microSD 64 GB Ultra A1 (doporučeno), box A | 1 | **699 Kč** | [hledání](https://www.alza.cz/search.htm?exps=sandisk+ultra+a1+64gb) |
|   alt. Extreme A2 799 / Extreme PRO 829 Kč | — | viz vedle | [hledání](https://www.alza.cz/search.htm?exps=sandisk+extreme+64gb+microsd) |
| microSD 32 GB A1 (boxy B/C) | 2 | **499 Kč** | [hledání](https://www.alza.cz/search.htm?exps=sandisk+ultra+32gb+a1+microsd) |
| **USB zvuková karta** (USB-A → 3,5 mm jack) — **pro všechny 3 boxy** (Pi Zero nemá jack → nově stavíme jen s Pi 4, ale sjednoceno na USB zvukovce) | 3 | ≈115–150 Kč | [hledání](https://www.alza.cz/search.htm?exps=gembird+usb+audio+adapter) |
| micro-HDMI → HDMI kabel 1,8 m (setup/konzole) | 1 | **109 Kč** (3 m 125) | [hledání](https://www.alza.cz/search.htm?exps=micro+hdmi+hdmi+kabel) |
| Stativ na kameru: Apexel Mini Tripod | 1 | **189 Kč** (rozkládací 459) | [hledání](https://www.alza.cz/search.htm?exps=apexel+mini+tripod) |
| **Boxy** — konstrukční krabička MASZCZYK KM-85 (180×160×84 mm) ×3 — z GME, viz §3 | 3 | **209 Kč** | [gme.cz](https://www.gme.cz/v/1508143/maszczyk-km-85-abs-black-krabicka-plastova) |

**Alza mezisoučet ≈ 13 600 Kč (C270) / 14 600 Kč (C920)** (3× Pi 4, 3× ODS-721, 3× PSU, webkamera, SD karty, 3× USB zvukovka, mikro-HDMI, stativ).

> Pi 4 má sám 3,5 mm jack, ale dle požadavku je ve **všech** boxech použitá sjednocená **USB zvuková karta**
> a stereo výstup 3,5 mm je vyveden **jackem na panelu** krabice (interní jack Pi se nepoužívá).

---

## 3) Objednávkový list — GME (gme.cz): elektroboxy, šňůry, elektronika B/C, RF tlačítka, jacky

### 3.1 Elektroboxy (3 ks)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| MASZCZYK KM-85 ABS černá, 180×160×84 mm, 4dílná (doporučeno pro A, B i C — dost místa) | 3 | **209 Kč** /ks | [product](https://www.gme.cz/v/1508143/maszczyk-km-85-abs-black-krabicka-plastova) |
|   alt. MASZCZYK Z30A 120×70×46 mm (úspora místa v B/C) | 2 | 120 Kč /ks | [product](https://www.gme.cz/v/1514976/maszczyk-z30a-abs-blackkp21-krabicka-plastova) |
|   alt. KRADEX Z25 PS 220×220×78 mm (pro „stůl", větší) | — | 182 Kč /ks | [product](https://www.gme.cz/v/1508799/kradex-z25-ps-blackkp15-krabicka-plastova) |

**Krabice celkem ≈ 630 Kč** (KM-85 ×3).

### 3.2 Napájecí šňůry, kabeláž a elektro drobnosti

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| Napájecí flexo JT003 H05VV-F 3×1,5 mm², černá, **5 m** (2 ks = 10 m, nejdelší běžný kus e-shopu) | 2 | **175 Kč**/ks | [product](https://www.gme.cz/v/1509985/jt003-h05vv-f-3x15-cerna-5m-napajeci-sitovy-kabel-flexo) |
| Krátká napájecí šňůra JT003 3×1,5, **2 m**, černá/bílá (do B a C) | 2 | **89 Kč**/ks | [product](https://www.gme.cz/v/1510505/jt003-h05vv-f-3x15-cerna-2m-napajeci-sitovy-kabel-flexo) |
| Lanko CYA 1×0,5 mm² (H05V-K), 3,50 Kč/m — cca 5 m/barva (černá, červená, žlutá, zelená, modrá, hnědá) | 30 m | **3,50 Kč/m** | [černý 1512360](https://www.gme.cz/v/1512360/elektrokabel-cya-1x05-cerny-h05v-k-izolovany-vodic-lanko) / [kategorie](https://www.gme.cz/c/15098/cya-jednozilove-vodice-lanko) |
| Svorkovnice KLS 301-5.00-02P 2pól 5 mm 16 A (přípojka 230 V v A + rozvod) | 10 | **5 Kč**/ks | [product](https://www.gme.cz/v/1497538/kls-301-500-02p-2-sc-svorkovnice-2pol-roztec-5mm-16a-250v-vstup-90-sroub) |
| Sada smršťovacích bužírek KSS VS-100BK | 1 | **135 Kč** | [product](https://www.gme.cz/v/1483738/kss-vs-100bk-sada-smrstovacich-buzirek) |
| Distanční sloupek M2,5 × 10 mm, matka/šroub (DA5M2,5X10) — Pi 4 se montuje na sloupky | 40 | **5,50 Kč**/ks | [product](https://www.gme.cz/v/1482591/da5m25x10-nikl-distancni-sloupek-10mm-m25-matka-sroub) |

### 3.3 Stereo výstupy na panelech (3 ks) a rozdvojky (B/C)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| **Jack 3,5 mm stereo, zásuvka do panelu, EY-512C** — výstup na čelní stěně každé krabice | 3 | **15 Kč**/ks | [product](https://www.gme.cz/v/1496892/ey-512c-jack-35-stereo) |
| Rozdvojka PremiumCord JACK 3,5 M → 2× JACK 3,5 F (USB zvukovka → panel + interní zesilovač) | 2 | **25 Kč**/ks | [product](https://www.gme.cz/v/1496896/premiumcord-jack-35-m-2x-jack-35-f-stereo-10cm-rozdvojka) |

**Jacky + rozdvojky = 95 Kč.**

**Šňůry + kabeláž + drobnosti + jacky ≈ 1 085 Kč.**

### 3.4 Jeden box (stejný pro A, B i C — elektronika bez boxu A-příslušenství) 

> Elektronika boxů B a C je **přesně stejná jako box A** až na: webkameru, SD 64 GB, mikro-HDMI a stativ (jen box A).
> Níže je kusovník „jádra" boxu (×3); specifické položky boxu A viz §2.

| Položka | Kusy (×3) | Cena /ks | Odkaz |
|---------|-----:|-----:|-------|
| Raspberry Pi 4 Model B 4 GB | 3 | **3 029 Kč** | [hledání Alza](https://www.alza.cz/search.htm?exps=raspberry+pi+4+4gb) |
| Krabička ODS-721 + zdroj 15,3 W (Alza, §2) | 3+3 | ≈259 + od 251 Kč | [hledání](https://www.alza.cz/search.htm?exps=inter-tech+ods-721) |
| Znakový LCD 16×2 alfanumerický (DM1602AYG) + I2C převodník PCF8574 *(jen B a C)* | 2 | LCD **85** + adapter **69 Kč** | [LCD](https://www.gme.cz/v/1495826/dm1602ayg-alfanumericky-lcd-displej) + [I2C](https://www.gme.cz/v/1508988/adapter-prevodnik-i2c-pro-displej-lcd1602-a-2004) |
| Digitální zesilovač **CREATALL CA-3110S** (TP3110, třída D), *(jen B a C)* | 2 | **49 Kč** | [product](https://www.gme.cz/v/1518915/creatall-ca-3110s-digitalni-zesilovac-tridy-d-s-cipem-tp3110-napajeni-826v-3a) |
| Reproduktor 40 mm, 8 Ω (LS40N-27-R8), *(jen B a C)* | 2 | **62 Kč** | [product](https://www.gme.cz/v/1497252/ls40n-27-r8-reproduktor) |
| USB zvuková karta (USB-A → 3,5 mm) — ve všech boxech | 3 | ≈115–150 Kč | [hledání Alza](https://www.alza.cz/search.htm?exps=gembird+usb+audio+adapter) |
| RF přijímač 433 MHz SRX882S (ASK), *(jen B a C)* | 2 | **79 Kč** | [product](https://www.gme.cz/v/1514654/srx882s-prijimac-433mhz-ask) |
| Stereo jack 3,5 do panelu EY-512C (§3.3) | 3 | **15 Kč** | [product](https://www.gme.cz/v/1496892/ey-512c-jack-35-stereo) |
| Reset tlačítko: mikrospínač 6×6 mm + LED 5 mm + rezistor 330 Ω/10 kΩ | 3 sady | ≈20 Kč | [mikrospínač](https://www.gme.cz/v/1501885/wealthmetal-tc-0107-t-mikrospinac) |
| Krabička MASZCZYK KM-85 (§3.1) | 3 | 209 Kč | [product](https://www.gme.cz/v/1508143/maszczyk-km-85-abs-black-krabicka-plastova) |

**Jádro jednoho boxu ≈ 3 900 Kč (box A); samplerový box B/C (+LCD, amp, repro, RX, rozdvojka) ≈ 4 800 Kč.**
*(Pozn: jádro = Pi 4 + ODS-721 + zdroj + USB zvukovka + jack do panelu + reset sada + KM-85.)*

### 3.5 Bezdrátová tlačítka (20 ks) — hotová, 433 MHz

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| **Solight 1L67T** bezdrátové tlačítko pro zvonek 1L67 (433 MHz, learning-code, 200 m, kryt na jmenovku, baterie uvnitř) | 20 | **72,60 Kč** (VÝPRODEJ) | [GME – vyhledání](https://www.gme.cz/vysledky-vyhledavani?q=Solight+1L67T) / kód 757-233 |
| *(volitelně)* Náhradní baterie CR2032, blistr 5 ks (Camelion BP5) | 4 (20 ks) | **19 Kč**/blistr | [product](https://www.gme.cz/v/1519272/camelion-cr2032-bp5-lithiova-knoflikova-baterie-blistr-5ks) |

**Tlačítka celkem ≈ 1 450 Kč (+ 76 Kč náhradní baterie).**
> Upozornění: položka je ve **výprodeji**, dostupná jen na 2 prodejnách — objednat co nejdříve.

---

## 4) Napájení a rozvod (předpoklad)

- **230 V**: 2× flexo 5 m (celkem 10 m) H05VV-F 3×1,5 — koncovka šňůry do elektroboxu **A** (přípojka na svorkovnici KLS, vývod PE).
- **V boxu A**: svorkovnice rozdělí síť: L/N/PE jde do hlavního zdroje A (Pi 4) **a dál krátkou 2 m šňůrou do boxů B a C**.
- **Každý box má vlastní** oficiální zdroj RPi 15,3 W (USB-C 5,1 V / 3 A) — Pi 4 bere až 3 A, takže rozvod 5 V „lankem z A" se nedoporučuje (varianta 5 V lanka z předchozí verze rušena).
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

### 5.3 Zvukový výstup (USB zvukovka → panelový stereo jack) — ve všech boxech

```
USB zvuková karta (USB-A na Pi)             B/C:
  [stereo výstup 3,5 mm] ──► [Y-rozdvojka PremiumCord] ──► jack EY-512C do panelu
       │ (A: přímo)                                   └─► CA-3110S vstup → LS40N
       └──► JACK 3,5 stereo do panelu (EY-512C)            (interní reproduktor B/C)
            TIP = L,  RING = R,  SLEEVE = GND
```
- Použít **vždy USB zvukovku**, ne interní jack Pi (interní jack se nezapojuje).
- U B/C rozdvojka umožní paralelně: panelový výstup (na mix/pódiový zesilovač) **a** interní reproduktor.

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

## 7) Odhad finální ceny (upraveno 9. 9. 2026 — 3× Pi 4 + USB zvukovky + panelové jacky)

| Sestava | HW | Doprava (~2 e-shopy) | Práce | Rezerva 10 % | **Celkem** |
|---|---|---|---|---|---|
| **Minimální** (C270, 60 h) | ≈17 500 | ≈400 | 21 000 | ≈1 800 | **≈40 700 Kč** |
| **Doporučená** (C920, 80 h) | ≈18 500 | ≈400 | 28 000 | ≈1 900 | **≈48 800 Kč** |
| **Komfort** (C920 + C922 do C, 112 h) | ≈19 500 | ≈400 | 39 200 | ≈2 000 | **≈61 100 Kč** |

*Pozn.: HW vč. 3× Pi 4 (4 GB), 3× ODS-721, 3× zdroj 15,3 W, 3× USB zvukovka, 3× panelový jack,
2× LCD + amp + repro + RF RX, 20 hotových tlačítek, 10 m šňůry, kabeláže a drobností.*

---

## 8) Montážní checklist (RF 433 MHz, USB zvukovky, panelové jacky)

1. Zapájení/naddimenzování kabeláže do svorkovnic v boxu A (2× 5 m šňůra + rozvod 230 V, PG-kabelky).
2. Osazení boxu A: Pi 4 + ODS-721 + zdroj 15,3 W + webkamera na stativu + USB zvukovka + jack do panelu + kalibrace (README.md).
3. Box B: Pi 4 (stejný) + LCD 16×2 na GPIO + CA-3110S + LS40N + USB zvukovka + panelový jack + SRX882S; totéž box C.
4. 20 hotových tlačítek: dekódování kódu (RCSwitch), mapa kód → sample (10 → B, 10 → C).
5. Instalace OS (Raspberry Pi OS Lite), ovladače (opencv, raylib, SDL2_mixer, librc-switch, i2c-tools), služby (reset, zobrazení mixu, zvukový výstup přes USB zvukovku).
6. Test synchronizace A↔B↔C (WiFi), RF dosahu (433 MHz), audio výstupů na panelech (stereo jacky), zátěžový 2denní test.

---

## 9) Předpoklady / otevřené volby

- **Všechny boxy = Raspberry Pi 4 4 GB** (rozhodnuto) — jednotnost HW, dost USB pro webkameru + zvukovku, GPIO totožné s Pi Zero.
- **Audio: ve všech boxech USB zvuková karta + stereo jack 3,5 mm na panelu** (rozhodnuto); interní jack Pi 4 se nepoužívá. Interní reproduktor/zesilovač je jen v B a C.
- **RF: 433 MHz**, hotová tlačítka (Solight 1L67T + SRX882S); mimo WiFi pásmo; jednosměrné protokoly bez potvrzení.
- **Displej**: 16×2 I2C; alternativa malý OLED 0,91–1,3" (SSD1306).
- **Reset**: GPIO soft (shutdown); alternativa mechanický vypínač 230 V.
- Ceny ověřeny 9. 9. 2026; Solight 1L67T je **výprodej** — objednat co nejdříve; Pi 4/ODS-721/zdroje běžně skladem.