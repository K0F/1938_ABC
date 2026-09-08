# HW požadavky — Tracker (3 boxy)

Základní dokument pro stavbu hardwaru trackeru jako třídílného hudebního nástroje.
Ověřeno na **Alza.cz**, **GM Electronic (gme.cz)** a **RPishop.cz** dne **8. 9. 2026**. Ceny se liší dodací lhůtou a aktuální skladovostí — „≈" znamená orientační cenu, ostatní je ověřená.
Kompletní schémata všech propojení: [`docs/SCH.md`](docs/SCH.md).

---

## 1) Architektura a role boxů

| Box | Role | HW |
|-----|------|----|
| **A** | Hlavní jednotka — běží stávající software **tracker** (webkamera snímá stůl, koule ovládají hlasitost loopů přes SDL2_mixer). Rozvod sítě pro celou sestavu. | Raspberry Pi 4 4 GB + webkamera |
| **B** | **Spouštěč samplerů** — 10 bezdrátových tlačítek, SDL Mixer přehrává X samplů, malý reproduktor přímo v krabici, displej 16×2 se stavem mixu, indikace chodu + reset | Raspberry Pi Zero 2 WH + audio + LCD + RF přijímač 433 MHz |
| **C** | Stejná role jako B (druhá sekce, dalších 10 tlačítek) | Raspberry Pi Zero 2 WH + audio + LCD + RF přijímač 433 MHz |
| **20× tlačítko** | **Hotové bezdrátové tlačítko** Solight 1L67T (433 MHz, EV1527/learning-code, baterie uvnitř) | 10 ks spárováno s B, 10 ks s C |

Komunikace: tlačítka → RF **433 MHz** (ASK/OOK) → přijímač **SRX882S** v B/C (GPIO, knihovna RCSwitch) → SDL Mixer.
Synchronizace samplerů a trackeru mezi A a B/C: WiFi (B/C mají 2,4 GHz WiFi; sample lze rsyncovat z A).
Napájení: 230 V přivedeno **10 m šňůrou s koncovkou do elektroboxu A**; do B a C se rozvádí 5 V lankem (nebo krátkou síťovou šňůrou) — viz kapitola 4.

```
        [20× hotové tlačítko Solight 1L67T ─ cca 10/B, 10/C]
                        │ RF 433 MHz (ASK)
         ┌──────────────┼──────────────┐
         ▼              ▼              ▼
      [Box B]        [Box C]        [Box A]
      Pi Zero        Pi Zero        Pi 4 4GB + webkamera (tracker)
      SRX882S        SRX882S        (audio jack 3,5 mm)
      LCD 16×2       LCD 16×2
      repro+amp      repro+amp
         │              │              │  ← 5 V lanko / krátké šňůry
         └──────┬───────┴──────┬───────┘
      rozvod v boxu A ◄─── 10 m šňůra H05VV-F 3×1,5 s koncovkou (230 V)
```

---

## 2) Objednávkový list — Alza.cz (box A, karty, kabeláž, webkamera, stativ)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| Raspberry Pi 4 Model B 4 GB (doporučeno) | 1 | **3 029 Kč** | [hledání](https://www.alza.cz/search.htm?exps=raspberry+pi+4+4gb) |
| RPi 4B 8 GB / 3 GB / 2 GB (alternativa) | — | 4 629 / 2 239 / 1 899 Kč | [hledání](https://www.alza.cz/search.htm?exps=raspberry+pi+4) |
| Krabička na Pi 4: **Inter-Tech ODS-721 (hliník)** — JOY-IT RB-Heatsink je na Alze vyprodaný/chybí | 1 | **≈259 Kč** | [hledání](https://www.alza.cz/search.htm?exps=inter-tech+ods-721) |
|   alt. JOY-IT Armor / pasivní RB-Heatsink | — | 299 / 88 Kč | [hledání](https://www.alza.cz/search.htm?exps=joy-it+armor) |
| Oficiální zdroj RPi 15,3 W / USB-C 5,1 V 3 A | 1 | od **251 Kč** (černý skladem) | [hledání](https://www.alza.cz/search.htm?exps=raspberry+pi+15.3w) |
| **Webkamera** Logitech C270 HD (rozpočet) | 1 | **599–799 Kč** | [hledání](https://www.alza.cz/search.htm?exps=logitech+c270) |
| **Webkamera** Logitech C920 Full HD (doporučeno, lepší obraz a stálost) | 1 | **1 599 Kč** | [hledání](https://www.alza.cz/search.htm?exps=logitech+c920) |
|   alt. C922 2 499 / C920s 2 299 / Brio 300 1 299 / Brio 100 749 Kč | — | viz vedle | [hledání](https://www.alza.cz/search.htm?exps=logitech+webkamera) |
| microSD 64 GB SanDisk Ultra (rozpočet) | 1 | **549 Kč** | [hledání](https://www.alza.cz/search.htm?exps=sandisk+ultra+64gb+microsd) |
| microSD 64 GB Ultra A1 (doporučeno) | 1 | **699 Kč** | [hledání](https://www.alza.cz/search.htm?exps=sandisk+ultra+a1+64gb) |
|   alt. Extreme A2 799 / Extreme PRO 829 Kč | — | viz vedle | [hledání](https://www.alza.cz/search.htm?exps=sandisk+extreme+64gb+microsd) |
| micro-HDMI → HDMI kabel 1,8 m (setup/konzole), JOY-IT | 1 | **109 Kč** (3 m 125) | [hledání](https://www.alza.cz/search.htm?exps=micro+hdmi+hdmi+kabel) |
| Stativ na kameru: Apexel Mini Tripod | 1 | **189 Kč** (rozkládací 459) | [hledání](https://www.alza.cz/search.htm?exps=apexel+mini+tripod) |
| **Box A** — konstrukční krabička MASZCZYK KM-85 (180×160×84 mm) — z GME, viz §3 | 1 | **209 Kč** | [gme.cz](https://www.gme.cz/v/1508143/maszczyk-km-85-abs-black-krabicka-plastova) |

**Mezisoučet boxu A ≈ 5 000 Kč** (C270) / **≈ 5 400 Kč** (C920) bez krabičky A (209 Kč je v §3).

> Pi 4 má 3,5 mm jack — pro tracker není potřeba žádná zvuková karta. Volitelně repro Creative Pebble 529 Kč.

---

## 3) Objednávkový list — GME (gme.cz): elektroboxy, šňůry, elektronika B/C, RF tlačítka

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
| Krátká napájecí šňůra JT003 3×1,5, **2 m**, černá/bílá (rozvod na B/C) | 2 | **89 Kč**/ks | [product](https://www.gme.cz/v/1510505/jt003-h05vv-f-3x15-cerna-2m-napajeci-sitovy-kabel-flexo) |
| Lanko CYA 1×0,5 mm² (H05V-K), 3,50 Kč/m — cca 5 m/barva (černá, červená, žlutá, zelená, modrá, hnědá) | 30 m | **3,50 Kč/m** | [černý 1512360](https://www.gme.cz/v/1512360/elektrokabel-cya-1x05-cerny-h05v-k-izolovany-vodic-lanko) / [kategorie](https://www.gme.cz/c/15098/cya-jednozilove-vodice-lanko) |
| Svorkovnice KLS 301-5.00-02P 2pól 5 mm 16 A (přípojka 230 V v A + rozvod) | 10 | **5 Kč**/ks | [product](https://www.gme.cz/v/1497538/kls-301-500-02p-2-sc-svorkovnice-2pol-roztec-5mm-16a-250v-vstup-90-sroub) |
| Sada smršťovacích bužírek KSS VS-100BK | 1 | **135 Kč** | [product](https://www.gme.cz/v/1483738/kss-vs-100bk-sada-smrstovacich-buzirek) |
| Distanční sloupek M2,5 × 10 mm, matka/šroub (DA5M2,5X10) | 20 | **5,50 Kč**/ks | [product](https://www.gme.cz/v/1482591/da5m25x10-nikl-distancni-sloupek-10mm-m25-matka-sroub) |

**Šňůry + kabeláž + drobnosti ≈ 990 Kč.**

### 3.3 Box B i C — díl (stejný seznam ×2)

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| Raspberry Pi Zero 2 WH (s osazenými GPIO piny, jinak nelze LCD zapojit) — **RPishop v skladu** | 2 | **≈410 Kč** | [RPishop](https://rpishop.cz/zero/4311-raspberry-pi-zero-2-w-5056561800004.html) |
| Znakový LCD 16×2 alfanumerický (DM1602AYG) + I2C převodník PCF8574 | 2× (LCD+adapter) | LCD **85 Kč** + adapter **69 Kč** | [LCD](https://www.gme.cz/v/1495826/dm1602ayg-alfanumericky-lcd-displej) + [I2C adapter](https://www.gme.cz/v/1508988/adapter-prevodnik-i2c-pro-displej-lcd1602-a-2004) |
| Digitální zesilovač **CREATALL CA-3110S** (TP3110, třída D) — náhrada za vyprodaný PAM8403 | 2 | **49 Kč** | [product](https://www.gme.cz/v/1518915/creatall-ca-3110s-digitalni-zesilovac-tridy-d-s-cipem-tp3110-napajeni-826v-3a) |
| USB zvuková karta (USB-A → 3,5 mm jack) — Pi Zero nemá jack; zařazeno na Alza | 2 | ≈115–150 Kč | [hledání Alza](https://www.alza.cz/search.htm?exps=gembird+usb+audio+adapter) |
| Reproduktor 40 mm, 8 Ω (LS40N-27-R8) | 2 | **62 Kč** | [product](https://www.gme.cz/v/1497252/ls40n-27-r8-reproduktor) |
| **RF přijímač 433 MHz SRX882S (ASK)** — náhrada za nRF24L01+ (nová architektura tlačítek, §3.4) | 2 | **79 Kč** | [product](https://www.gme.cz/v/1514654/srx882s-prijimac-433mhz-ask) |
| microSD 32 GB A1 | 2 | **499 Kč** | [Alza](https://www.alza.cz/search.htm?exps=sandisk+ultra+32gb+a1+microsd) |
| Reset tlačítko: mikrospínač 6×6 mm + LED 5 mm + rezistor 330 Ω/10 kΩ kapely od 1,10 Kč; sloupky ze §3.2 | 2 sady | ≈20 Kč | [mikrospínač](https://www.gme.cz/v/1501885/wealthmetal-tc-0107-t-mikrospinac) |
| Krabička MASZCZYK KM-85 (§3.1) | 2 | 209 Kč | [product](https://www.gme.cz/v/1508143/maszczyk-km-85-abs-black-krabicka-plastova) |

**Jeden box B/C ≈ 1 760 Kč → oba ≈ 3 520 Kč.**

### 3.4 Bezdrátová tlačítka (20 ks) — hotová, 433 MHz

| Položka | Kusy | Cena | Odkaz |
|---------|-----:|-----:|-------|
| **Solight 1L67T** bezdrátové tlačítko pro zvonek 1L67 (433 MHz, learning-code, 200 m, kryt na jmenovku, baterie uvnitř) | 20 | **72,60 Kč** (VÝPRODEJ) | [GME – vyhledání](https://www.gme.cz/vysledky-vyhledavani?q=Solight+1L67T) / kód 757-233 |
| *(volitelně)* Náhradní baterie CR2032, blistr 5 ks (Camelion BP5) | 4 (20 ks) | **19 Kč**/blistr | [product](https://www.gme.cz/v/1519272/camelion-cr2032-bp5-lithiova-knoflikova-baterie-blistr-5ks) |

**Tlačítka celkem ≈ 1 450 Kč (+ 76 Kč náhradní baterie).**
> Upozornění: položka je ve **výprodeji**, dostupná jen na 2 prodejnách — objednat co nejdříve. Nelze-li 20 ks, zbytek dořešit tlačítky Solight 1L67DT / Honeywell DCP711G.

---

## 4) Napájení a rozvod (předpoklad)

- **230 V**: 2× flexo 5 m (celkem 10 m) H05VV-F 3×1,5 — koncovka šňůry do elektroboxu **A** (přípojka na svorkovnici KLS, vývod PE).
- **V boxu A** stojí oficiální zdroj 15,3 W (Pi 4, USB-C).
- **Pro B a C** dvě možnosti:
  - *(a) Doporučeno:* 5 V rozvod lankem 0,75–1,5 mm² z A do B a C (na ~2 m je úbytek v pořádku při odběru <1,5 A); celkem jen 1 síťová šňůra.
  - *(b) Jednodušší:* každý box vlastní malý 5 V mikro-USB zdroj napájený krátkou 2 m šňůrou z A (§3.2).
- Uvnitř boxů vše na svorkovnice/lanko (žádné holé kabely v blízkosti hran krabice), gumové průchodky na vývody.
- **Reset tlačítko + indikace chodu**: dedikovaný GPIO pin → čistý shutdown/restart (systemd), power-LED na GPIO s rezistorem 330 Ω.

---

## 5) Schémata zapojení (GPIO, boxy B/C, RF 433 MHz)

> **Kompletní schémata všech propojení (box A, B, C, tlačítka, rozvod): [`docs/SCH.md`](docs/SCH.md)**

### 5.1 Dvouřádkový displej 16×2 (I2C, PCF8574) na GPIO Pi Zero 2 WH

| Pi Zero GPIO (pin) | LCD modul | Poznámka |
|--------------------|-----------|----------|
| 3V3 (pin 1) | VCC | viz napájení níže |
| GND (pin 6) | GND | |
| GPIO 2 / SDA (pin 3) | SDA | |
| GPIO 3 / SCL (pin 5) | SCL | |

- Modul (LCD + I2C adapter) je stavěn na **5 V** (HD44780 + PCF8574). **Bezpečné zapojení na GPIO:**
  - buď napájet VCC jen **3,3 V** (HD44780 reálně funguje, kontrast upravit potenciometrem na adaptéru), *nebo*
  - přidat **level shifter 3,3→5 V** na SDA/SCL a napájet modul 5 V z pinu 2/4.
- Pull-up rezistory jsou obvykle na I2C modulu; při potížích doplnit 4,7 kΩ na 3,3 V.
- Adresa: **0x27** (někdy 0x3F) — zjistit `i2cdetect -y 1`.
- Aktivace rozhraní: `raspi-config` → Interface → I2C, nebo do `/boot/config.txt` přidat `dtparam=i2c_arm=on`.

Zobrazení: řádek 1 = „MIX B" + aktivní samply, řádek 2 = hlasitosti/stav (formát řeší SW sampleru).

### 5.2 Reset tlačítko + indikace chodu

```
Pi Zero GPIO17 (pin 11) ──┬── TLAČÍTKO (NO) ── GND
                          └── 10 kΩ pull-up ── 3V3      (software: debounce)
Pi Zero GPIO26 (pin 37) ──┬── 330 Ω ── LED [+] ── GND   (indikace chodu)
```
- Krátké stisknutí → `systemctl poweroff` (či restart), dvojité → restart. Skript + systemd unit dodá SW sampleru.
- U boxu A totéž na GPIO piny Pi 4 (BCM 17/26).

### 5.3 RF přijímač 433 MHz (SRX882S) na Pi Zero v B/C

```
Pi Zero GPIO22 (pin 15) ◄── DATA ── SRX882S [VCC ◄── 3V3 (pin 1)]
Pi Zero GND (pin 6)    ◄────── GND ── SRX882S [ANT ── integrovaná anténa]
```
- Modul SRX882S (ASK/OOK, 433,92 MHz) — DATA výstup je logika 3,3 V, napájet **3V3** (lze i 5 V, výstup pak high 5 V → nedoporučeno na GPIO bez přerušení).
- Stisk hotového tlačítka = krátký burst kódu (EV1527/learning-code). Pi dekóduje přes `rc-switch`/`433Utils` (`RCSwitch` v C, GPIO 22 default).
- **Mapování tlačítek**: jeden stisk u každého tlačítka → `RCSwitch_Receive` vypíše kód; uložit mapu `kód → číslo sample` (10 ks pro B, 10 ks pro C). Párování s přijímačem není potřeba — jen dekódování.
- Dosah 200 m (uvnitř typicky 30–60 m), žádné sdílení pásma s WiFi 2,4 GHz.

---

## 6) Kalkulace práce (instalace)

Sazba **350 Kč/h**, ideální délka instalace **2 týdny**.

| Varianta | Hodin | Práce |
|---|---|---|
| 2 týdny × 6 h/den (10 prac. dní) | 60 h | 21 000 Kč |
| **2 týdny × 8 h/den (doporučeno / ideál)** | **80 h** | **28 000 Kč** |
| 2 týdny × 8 h včetně víkendů | 112 h | 39 200 Kč |

---

## 7) Odhad finální ceny (upraveno 8. 9. 2026 — hotová tlačítka 433 MHz)

| Sestava | HW | Doprava (~3 e-shopy) | Práce | Rezerva 10 % | **Celkem** |
|---|---|---|---|---|---|
| **Minimální** (C270, 60 h) | ≈10 600 | ≈400 | 21 000 | ≈1 100 | **≈33 100 Kč** |
| **Doporučená** (C920, 80 h) | ≈11 600 | ≈400 | 28 000 | ≈1 200 | **≈41 200 Kč** |
| **Komfort** (C920 + C922 do C, 112 h) | ≈12 700 | ≈400 | 39 200 | ≈1 300 | **≈53 600 Kč** |

*Pozn.: HW je počítán vč. 3 elektroboxů, 20 hotových tlačítek, 10 m šňůry, kabeláže a drobností; nezahrnuje výrobní desky plošných spojů (→ prototyp na nepájivém poli).*

---

## 8) Montážní checklist (aktualizováno na RF 433 MHz)

1. Zapájení/naddimenzování kabeláže do svorkovnic v boxu A (2× 5 m šňůra + rozvod, PG-kabelky).
2. Osazení boxu A: Pi 4 + krabička (ODS-721) + zdroj 15,3 W + webkamera na stativu nad hrací plochou + kalibrace (viz `README.md`).
3. Box B: Pi Zero 2 WH + LCD 16×2 na GPIO + CA-3110S + LS40N + USB zvukovka + **SRX882S**; totéž box C.
4. 20 hotových tlačítek Solight 1L67T: dekódování kódu každého (RCSwitch), mapa kód → sample (10 → B, 10 → C).
5. Instalace OS (Raspberry Pi OS Lite), ovladače (opencv, raylib, SDL2_mixer, **librc-switch**/433Utils, i2c-tools), systémové služby (reset, zobrazení mixu).
6. Test síťové synchronizace A↔B↔C (sběr samplerů), test RF dosahu (433 MHz), výdrž baterií tlačítek.
7. Závěrečný 2denní zátěžový test + dokumentace ke krabicím.

---

## 9) Předpoklady / otevřené volby

- **B/C** mají vlastní mini-Pi (Zero 2 WH); pokud chceš pasivní B/C jen jako panely tlačítek, HW i SW se zjednoduší (odpadnou 2× Pi, LCD, repro, USB zvukovka ≈ –3 520 Kč).
- **RF: ROZHODNUTO — 433 MHz**, hotová tlačítka (Solight 1L67T + SRX882S). Pořizovací náklad ≈ 1 450 Kč místo ≈ 4 300 Kč u DIY nRF24L01 uzlů; mimo WiFi pásmo. Nevýhoda: pomalejší (desítky ms), jednosměrné protokoly bez potvrzení.
- **Displej**: 16×2 I2C (DM1602AYG + PCF8574 adapter); alternativa malý OLED 0,91–1,3" (SSD1306).
- **Reset**: GPIO soft (shutdown), alternativa mechanický vypínač 230 V.
- Ceny ověřeny 8. 9. 2026; dostupnost Pi Zero 2 W v ČR kolísá (vyprodává se) — objednat dříve; Solight 1L67T je **výprodej**.