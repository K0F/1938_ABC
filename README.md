# Multi-Track Audio Tracker & RF Sampler

Tento repozitář obsahuje dvě hlavní aplikace vytvořené pro interaktivní zvukovou instalaci:
1. **Tracker (Box A)**: Přehrávač osmi synchronních smyček řízený webkamerou. Dvě barevné koule (zelená/červená) modulují hlasitost podle polohy nad hrací plochou (s korekcí perspektivy). Do stejné binárky je vložený i sampler: 433 MHz RF tlačítka přes `map.csv` přidávají jednorázové vzorky a tlačítko F (`@interact`) pouští/zastavuje smyčky.
2. **Sampler (Box B/C)**: Samostatný bezdrátový sampler, ve kterém 433 MHz RF tlačítka spouští jednorázové zvukové samply.

**Režie:** Barbora Jeřábková, Lucia Schubert 
**Realizace:** Pavel Sterec, Matouš Hakela, Kryštof Pešek  
**Produkce:** Jakub Beran

---

## 1. Tracker (Box A)

Tracker používá webkameru k detekci dvou barevných koulí nad hrací plochou a mapuje jejich polohu (rektifikované X/Y) na hlasitost neustále hrajících zvukových smyček. Všech **8 smyček** se nahraje a spustí naráz; znějí ale jen když je zapnutá **interaction** (tlačítko F na 433 MHz). RF tlačítka z `map.csv` přidávají do mixu jednorázové vzorky.

### Jak to funguje
- **Zelená koule** plynule prolíná (2D crossfade) 4 náladové stopy `Interactive_music_*` podle rektifikované polohy X/Y: `Y-up_WAR`, `Y-down_PEACE`, `X-left_DRAMA`, `X-right_INTIMACY`. Mezi kvadranty se prolíná spojitě, uprostřed znějí všechny čtyři.
- **Červená koule** kvadrantem **tvrdě přepíná (on/off)** 4 intermezza: `I1`=`Inter_Mobilizace_Cisla`, `I2`=`Inter_Emil_Hacha`, `I3`=`Inter_Mobilizace_Emoce`, `I4`=podklad `track9` (dřív samostatný „bed“). Vždy hraje nejvýš jedna.
- Detekce je barevná (HSV blob) — žádný MOG2 ani KCF, jen převod do HSV a pár prahů na snímek, což je na Raspberry Pi 4 zanedbatelné. Barvy koulí se „naučí“ kliknutím do okna (viz [Ovládání](#ovládání-tracker)); dokud naučené nejsou, použijí se pevné prahy (zelená/červená).
- Sledování je odolnější: střed bere z `minEnclosingCircle` (ne z bboxu, který posouvá odlesk), tvar filtruje kruhovostí (`--min-roundness`) a mezemi plochy (`--min-area`/`--max-area`). Zamčená koule se hledá v úzkém okně kolem predikce (okno roste s rychlostí), ztracená nejdřív v okruhu `--reacquire-px` kolem poslední polohy a teprve pak globálně — koule tak „nepřeskočí“ na jiný objekt; blob blíž k druhé kouli se zahodí (záměna koulí). Polohu hlazuje drobný 1D Kalman s konstantní rychlostí (plynulý pohyb, krátké výpadky předpoví). Naučená saturace/jas se pomalu přizpůsobují změně osvětlení (`--adapt-alpha`), odstín zůstává naučený; `--lock-exposure` navíc vypne auto-expozici/WB kamery.
- **Odstranění pozadí**: na prázdné ploše (koule mimo stůl) se změří referenční snímek (klávesa `B`, soubor `--bg`, default `bg.bin`); detekce pak bere jen pixely, které se od reference liší (`--bg-diff`, `--no-bg` vypne). Zmizí statické odlesky a barevné předměty v pozadí, ale koule zůstane detekovaná i když se nehýbe (na rozdíl od MOG2). S `--lock-exposure` zůstává reference platná i při změnách světla.
- Když je interaction vypnutá, jsou všechny smyčky ztlumené (ticho). RF tlačítka hrají navrch bez ohledu na to.

### Korekce perspektivy a učení barev
Pokud je webkamera nakloněna, může být sledovaná plocha zkreslená. Software to koriguje pomocí homografické projekce.
- **Táhnutím** 4 rohových bodů (červené kruhy = osa X, modré kruhy = osa Y) ohraničíte reálnou sledovanou plochu.
- **S** – uloží kalibraci do `calib.txt` (rohy, naučené barvy i tolerance; automaticky se načte při dalším spuštění).
- **R** – resetuje rohy na plný snímek.
- **Klik do koule** – naučí barvu: levé tlačítko naučí zelenou (nálady), pravé tlačítko červenou (intermezza). Klik mimo rohový bod učí, na rohu táhne kalibraci.
- **`C`** – zapomene naučené barvy (zpět na pevné prahy). **`B`** – změří referenci prázdné plochy (drž koule mimo stůl). **`[`** / **`]`** – zúží/rozšíří toleranci odstínu (`hueTol`, uloží se).

Barvy i rohy se ukládají do `calib.txt` včetně rozlišení, pro které platí — když se později změní `--width/--height`, rohy se automaticky přepočítají (`calib: rohy přepočítány z … na …`). Pro snazší vizualizaci rektifikace je přes obraz překryta perspektivní mřížka.

### Závislosti (Tracker)
| Knihovna | Verze | Poznámky |
|---------|---------|-------|
| Raylib | 5.x-6.x | Vykreslování oken a vstup |
| grayskull | header-only | Vision: bloby, morfologie, perspektiva (`third_party/`) |
| libjpeg-turbo | 2.x | Dekódování MJPEG z V4L2 kamery |
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
Vložte smyčky do složky `samples/` pod jmény, která tracker očekává:
`samples/Interactive_music_{Y-up_WAR,Y-down_PEACE,X-left-DRAMA,X-right-INTIMACY}.wav`,
`samples/Inter_{Mobilizace_Cisla,Emil_Hacha,Mobilizace_Emoce}.wav` a `samples/track9.wav` (čtvrté intermezzo `I4`). Chybějící vzorek tracker jen zaloguje (`audio: missing …`) a jede dál.

```bash
./tracker                  # okenní režim (kalibrace, naučení barev), 1280x720
./tracker --headless       # bez okna (Box A v produkci)
./tracker --width 1920 --height 1080   # jiné rozlišení kamery
./tracker --detect-ms 0    # detekce v každém snímku (bez throttlingu)
```
Přehled voleb: `--min-area N` (min. plocha blobu koule), `--max-area N` (max. plocha, `0` = bez limitu), `--min-roundness F` (kruhovitost blobu 0..1), `--gate-px N` (poloměr zámku kolem predikce v px, `0` = vypnuto), `--reacquire-px N` (poloměr hledání ztracené koule v px), `--adapt-alpha F` (rychlost adaptace naučené saturace/jasu), `--bg FILE`/`--bg-diff N`/`--no-bg` (reference prázdné plochy a její prah), `--lock-exposure` (vypne auto-expozici/WB kamery), `--detect-ms N` (max. frekvence CV detekce v ms, `0` = každý snímek), `--width/--height`, `--map FILE`, `--samples-dir D`, `--no-rf`, `--allow-restart`, `--simulate`; celý výpis `./tracker --help`.

### Headless režim (Box A v produkci)
Box A běží bez okna a bez X — grafiku nepotřebuje, jen kameru a zvuk. Služba běží jako **root** (kvůli akcím z `map.csv`, které volají `systemctl restart`):
```bash
./tracker --headless --allow-restart --map map.csv   # bez okna; vstup přes systemd
```
```bash
sudo cp tracker.service /etc/systemd/system/
sudo systemctl enable --now tracker
journalctl -t tracker -f   # logy do journalu
```
Okenný režim zůstává pro kalibraci (přetáhnutí rohů, klávesa `S`) a naučení barev klikem. Bez `calib.txt` tracker používá celý snímek, takže první kalibraci udělejte ještě s monitorem přes HDMI (nebo přes VNC, viz níže).

#### Autostart po restartu
`tracker.service` je `enabled` — po každém restartu boxu se tracker rozjede sám, bez monitoru a bez přihlášení. Když při startu ještě není kamera, služba zkusí znovu po 2 s; limit restartu je vypnutý (`StartLimitIntervalSec=0`), jinak by ji po pěti rychlých pokusech systemd zabil a tracker by zůstal tichý do ručního zásahu.
```bash
systemctl is-enabled tracker              # enabled
systemctl status tracker
journalctl -u tracker -b | head           # "tracker vX.Y.Z start: headless, no camera yet, … 1280x720 capture, 15Hz detect"
journalctl -u tracker -b | grep -iE 'camera|calib'  # otevření kamery, přepočet rohů při změně rozlišení
journalctl -u tracker -b | grep -i 'interaction'    # "interaction: on/off" — F přepnul smyčky
journalctl -u tracker -b | grep -i 'audio:'         # chybějící vzorky ("audio: missing …")
journalctl -u tracker -b | grep 'code='             # dekódované RF kódy z map.csv
```

#### Tlačítko F (433 MHz) — interaction
Box A má na GPIO15 přijímač SRX882S a tracker ho čte přes `map.csv`. Tlačítko **F** (kód `5089457`) je v mapě jako **`@interact`**: přepíná `interaction` — dokud je vypnutá, je všech osm smyček ztlumených (ticho), při zapnutí se rozejdou. V journalu to jde vidět jako `interaction: on` / `interaction: off`.

Tracker i sampler jsou sloučené do jedné binárky (RF dekodér je v `buttons.c`), takže RF link drží tracker sám a `tracker.service` běží bez `--no-rf` (používá `--map map.csv`). Původní chování (F restartuje službu) lze vrátit přes `--reset-code 5089457` — kód mimo mapu pak tracker čistě ukončí a `Restart=always` ho zvedne; v journalu je to `RF button F (code 5089457) -> restart`. Pin se nastaví `--rf-pin N`; `--no-rf` RF úplně vypne. Bez přijímače tracker běží dál a loguje `rf: receiver unavailable`.

#### Přehodí USB zvukové karty
Zvuková karta v boxu sedí za hubem a občas se přehodí. Starý PCM v trackeru přitom umře (`ALSA write failed (unrecoverable): No such device`) a SDL ho už znovu neotevře — služba by běžela dál potichá, hodiny bez zvuku. Proto tu běží `box-sound-restart.service`: udev pravidlo `99-box-sound.rules` ho probudí, jakmile se objeví nová zvuková karta, přenastaví `/etc/asound.conf` a restartuje tracker.
```bash
journalctl -u box-sound-restart -b       # "restartováno: tracker.service"
```
Karty se v configu odvolávají **jménem** (`hw:CARD=Adapter,DEV=0`), ne číslem — přehození USB portu tak nesmí přesměrovat zvuk jinam. `box-audio-test.sh` i `tests/test-box-alsa-setup.sh` obojí prověří. Box B má stejnou jednotku s `RESTART_UNITS=sampler.service`; když se restart při přehodení nechce, stačí `RESTART_UNITS=` prázdné.

Dvě věci, které tu neuhodl popis, ale jinak to nefunguje:

- Pravidlo musí zařízení otagovat `TAG+="systemd"`. Bez tagu systemd-udevd zařízení přehlížne a `SYSTEMD_WANTS` neřeší — jednotka se nespustí, aniž by to v logu bylo nějak vidět. Stejně postupují vlastní pravidla systemd v `99-systemd.rules`.
- Restart má záměrnou prodlevu (`SETTLE_SEC`, default 3 s), aby se karta stihla usadit. Při bootu to znamená, že se tracker startuje dvakrát (systemd, pak udev) a nahrává až druhý běh; bez prodlevy by se občas chytil ještě ne úplně připravenou kartu.

Ověření na skutečném boxu (bez fyzického přehazování — jde o unbind USB zařízení, události jsou stejné jako po přepojení):
```bash
echo 1-1.1 | sudo tee /sys/bus/usb/drivers/usb/unbind   # karta zmizí
journalctl -u box-sound-restart -b -n 5                 # "restartováno: tracker.service"
```
POZOR: unbind je jednosměrný. Na Raspberry Pi OS s jádrem 6.12 (rpi) se
zařízení po unbindu samo nevrátí a `/sys/bus/usb/drivers/usb/bind` skončí
`No such device` — karta se musí připojit fyzicky (zařízení na portu pak
ohlásí udev jako nové a obnova proběhne sama). Pro opakované testy bez
fyzického zásahu nepoužívej unbind, ale přepojuj vlastní USB rozbočovač.

### HDMI konzole (Box A — obraz na TV)
Když u boxu není monitor, ale je připojená TV, jde tracker spustit oknem, které
zaplní celou obrazovku: autologin na `tty1` → `xinit` → okno trackeru na celý
displej. Snímek kamery se do něj vpasuje se zachováním poměru stran (1280x720
na 16:9 TV sedí 1:1; jiné rozlišení se pillarbox/letterboxuje, bez zkreslení) —
řeší to tracker sám, viz `main.c`.

```bash
cd /home/pi/tracker
sudo ./box-console.sh on      # nainstaluje profil, autologin, relaci; přepojí login
./box-console.sh status       # režim, X, tracker, poslední logy
sudo ./box-console.sh off     # zpět na headless (tracker.service)
```
Do `/etc` se ukládá `box-console.sh`, `box-console.xinit` a
`getty-tty1-autologin.conf`; stav režimu je v `/etc/box-console-mode`. V konzoli
je `tracker.service` vypnutá — kameru i zvukovku smí mít otevřené jen jeden
proces, jinak by si ji rvaly (EBUSY) a nebyl by slyšet ani jeden.

#### Na tomhle boxu běží na softwarovém GL
Hardwarový GLX na Raspberry Pi (vc4) tu **neumí vytvořit kontext, který chce
GLFW**: X server přitom GLX nabízí normálně (`glxinfo` vidí 144 vizuálů, OpenGL
3.1 přes V3D), jen samotné okno skončí na
`GLX: Failed to create context: GLXBadFBConfig` a neobjeví se. Relace proto
běží na Mesa softwarovém GL (`LIBGL_ALWAYS_SOFTWARE=1`), který kontext vytvoří
vždy a přežije i restarty trackera. Je to nejdražší část: okenní běh v 1280x720
bere ~**1,5 jádra** (z toho většina je softwarové GL/llvmpipe), zatímco bezhlavý
`tracker.service` (bez kreslení) jen ~**0,8 jádra** — proto je produkce bezhlavá
a okno se pouští jen na kalibraci (VNC, viz [Vzdálený náhled](#vzdálený-náhled-vnc)). Na boxu, kde má
grafika vykonávat práci, to vypnout lze proměnnou:
```bash
BOX_CONSOLE_SOFTGL=0   # v box-console.xinit, kdyby box hardwarový GL uměl
```

#### Když na TV není okno
V konzoli se nesmí nic, co okno zruší. Konkrétně X nesmí přepnout do jiného
režimu výstupu — v 640x480 (kde GLX vizuály nejsou) okno nevznikne vůbec, ať
se k tomu režimu dostaneš přes `xrandr --mode`, `xrandr --fb`, `-screen` v
argumentu `xinit` nebo v `xorg.conf`. Proto se režim výstupu v konzoli vůbec
nemění: X běží v nativním režimu TV a okno má velikost monitoru.
```bash
journalctl -t box-console -b -n 20    # co relace dělá a proč něco selhalo
cat /tmp/box-console-tracker.log      # výstup trackera (začátek: "okno 1280x720, snímek 1280x720 x1 na (0,0)")
```
Relace běží, dokud tracker jede; když spadne dvakrát po sobě za dvě sekundy,
zvedne ho cyklus v `box-console.xinit`. Když se nedaří (chybí binárka, X bez
GLX), relace skončí a na TV zůstane login prompt, ať u něj člověk může —
jinak by TV blikala bez zjevu. Stejně po třech rychlých restartech skončí
profil: `box-console: X relace padá pořád dokola`. Po opravě `rm
/tmp/.box-console.fails` nebo `box-console.sh off && on`.

### Vzdálený náhled (VNC)
Produkce je bezhlavá (`tracker.service`), ale na kalibraci, naučení barev nebo kontrolu detekce se hodí vidět obraz. V repu je trojice jednotek, které zvednou okenní session bez monitoru — Xvfb `:99` + tracker v okně + x11vnc na portu 5900. Jsou **jen pro debug** a nezapínají se při bootu; spouští se ručně (klidně z openbox menu na boxu):
```bash
sudo systemctl start tracker-vnc   # vytáhne i Xvfb + x11vnc; zastaví tracker.service
systemctl status tracker-vnc
sudo systemctl stop tracker-vnc    # ukončí view; `systemctl enable --now tracker` vrátí bezhlavou produkci
```
Jednotky se instalují při provisioningu Boxu A (`box-provision.sh`), ale zůstávají *disabled*. Alternativně totéž umí `./tracker-view.sh start|stop|status`.

Připojení z notebooku (TigerVNC, heslo `tracker`):
```bash
vncviewer -passwd vnc.passwd -Shared <boxa>::5900
```
Kameru a zvukovku smí držet jen jeden proces, proto se okenní (`tracker-vnc`) a bezhlavá (`tracker.service`) služba vzájemně vylučují přes `Conflicts=` (start jedné zastaví druhou).

### Ověření zvuku (Box A / Box B)
Box má USB zvukovou kartu i vestavěný jack Pi. `/etc/asound.conf` generuje skript `box-alsa-setup.sh`, který zařízení pojmenuje **podle typu**:
```bash
sudo ./box-alsa-setup.sh   # vygeneruje /etc/asound.conf
aplay -L | grep -E '^(usb|builtin|default)$'
```
| Zařízení | Typ | Popis |
|----------|-----|-------|
| `usb` | USB zvuková karta | AXAGON ADA-17 — hraje se do ní, živí zesilovač |
| `builtin` | vestavěný jack | bcm2835 Headphones (v krabici se nezapojuje) |
| `default` | = `usb` | tracker i sampler hrají sem, nemusí nic přepínat |

Test zvuku — služba drží kartu, proto nejdřív zastavit:
```bash
sudo systemctl stop tracker
speaker-test -D usb -c 2 -t sine -f 440 -l 1   # střídá levý/pravý kanál
aplay -D usb samples/track1.wav                # vlastní samply
sudo systemctl start tracker
```
`speaker-test` střídá kanály — tím ověříš `TIP = L, RING = R`. Obě zařízení jsou `type plug`, ne `type hw`: `hw` má pevně 2 kanály a mono samply by skončily chybou `Channels count non available`.

#### Automatický test zvuku

`box-audio-test.sh` spustí celý postup výše bez dohledu a výsledek uloží do `audio-test-report.txt`. Kontroluje, že `usb` a `default` jsou v `aplay -L`, že v configu není `device N`, že `pcm.usb` je `type plug`, a hlavně že **monofonní** `samples/track1.wav` skutečně přehraje. Bez `sudo` skript odmítne běžet — píše do `/etc/asound.conf` a staví služby. Test kartu drží zamčenou, proto tracker na začátku zastaví a na konci ho vždy pustí zpět, i když selhal; box tak nezůstane tichý.

Test logiky detekce běží bez QEMU i bez hardwaru — `box-alsa-setup.sh` čte kořene z proměnných (`ABC38_SOUND_SYSFS`, `ABC38_ASOUND_PROC`, `ABC38_ASOUND_CONF`), takže se dá pustit nad falešným stromem:
```bash
./tests/test-box-alsa-setup.sh
```
Pokrývá i případy, které se na boxu vyskytnou jen náhodou — hlavně **USB zařízení jen pro záznam (webkamera C920) nesmí být vybráno jako `usb`**, a to i když se vyloží dřív než zvukovka.

V QEMU se pustí celý průchod: QEMU emuluje USB zvukovku (`usb-audio`), test po bootu sám sebe spustí, zapíše report a vypne stroj.
```bash
./qemu_raspi4.sh setup          # qemu-system-aarch64 + qemu-user-static
./qemu_raspi4.sh audiotest      # prepare --audio-test + run --audio
./qemu_raspi4.sh report         # po skoncení QEMU vypsat výsledek
```
`audiotest` připraví image, pustí QEMU a nechá ho vypnout. Report se vypsá až naprázdno — `run` končí `exec`, takže po návratu do shellu ho musíš vypsat zvlášť příkazem `report`.

Hraný zvuk ukládá do `rom/guest-audio.wav`, takže se dá ověřit, že z hostu opravdu něco hrálo, ne že `aplay` jen skončil s 0. Bez binnfmt registrace `prepare` přes chroot doinstaluje `alsa-utils` selze — musí být zapnutý `sudo systemctl enable --now systemd-binfmt`.

QEMU má dvě omezení, která nejsou chyba testu: neemuluje `bcm2835` audio kodec, takže `pcm.builtin` v testu chybí, a jeho USB zvukovka není ADA-17 — ověřuje se detekce, config a cesta pro mono, ne hardware.

### Ovládání (Tracker)
| Vstup | Akce |
|-------|--------|
| Tažení myší / Dotyk | Přesun nejbližšího rohového bodu |
| Levé tlačítko mimo roh | Naučí **zelenou** kouli (4 náladové stopy) |
| Pravé tlačítko | Naučí **červenou** kouli (4 intermezza) |
| `S` | Uloží kalibraci (rohy + barvy + tolerance) do `calib.txt` |
| `R` | Resetuje rohy na celý obraz |
| `C` | Zapomene naučené barvy (zpět na pevné prahy) |
| `B` | Změří referenci prázdné plochy pro odstranění pozadí (drž koule mimo stůl) |
| `[` / `]` | Zúží / rozšíří toleranci odstínu (`hueTol`) a uloží |
| RF tlačítko `F` | `@interact` — zapne/vypne smyčky (kód `5089457`; viz též `--reset-code`) |

---

## 2. Sampler (Box B)

Sampler funguje jako samostatná bezdrátová spouštěcí jednotka. Využívá 433 MHz RF přijímač pro příjem signálů z 10 bezdrátových tlačítek (Solight 1L67T, protokol EV1527) a přehrává jednorázové zvukové samply přes `SDL2_mixer`. Také může volitelně aktualizovat stav úderů na 16×2 I2C displeji.

- RF kódy jsou dekódovány nativně na **GPIO15** (fyzický pin 33) pomocí interního EV1527 dekodéru přes `libgpiod` (není potřeba rc-switch/wiringPi).
- Samply jsou jednorázové: spouští se při každém stisknutí, přehrají se jednou a samy se zastaví.

> **Než připojíš tlačítko:** pin CS (4) SRX882S patří na 3V3. Volně ponechaný
> nebo na GND uspí modul — DATA pak trvale nízká, na GPIO žádné hrany a
> tlačítko vypadá jako mrtvé i s novou baterií. Podrobně `docs/SCH.md` §4.2.
>
> Tlačítko vysílá opakovaně, dokud je držené. Výchozí debounce 2000 ms. Při opakovaném stisku tlačítka, jehož vzorek právě hraje, se vrstva místo restartu pouze ztlumí (fade-out).
> přesahuje celý burst, takže jeden stisk = jedno přehrání. Kratší okno
> (např. `--debounce-ms 5000`) je vhodné v režimu hraní.
- Identita boxu (`b`) určuje, jaké samply a jaký mapovací soubor se použijí.

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
| `--box b` | — | Identita boxu (vyžadováno, zobrazeno na LCD) |
| `--map SOUBOR` | `map.csv` | Soubor mapující kódy na samply |
| `--samples-dir SLOŽKA` | `samples` | Složka obsahující WAV soubory |
| `--lcd-addr HEX` | `0x27` | I2C adresa PCF8574 displeje, nebo `off` |
| `--te-us N` | `320` | Základní časování EV1527 v µs (nutno doladit pro každé tlačítko) |
| `--debounce-ms N` | `2000` | Časové okno pro debounce každého tlačítka. Tlačítka vysílají kód opakovaně přes sekundu, takže kratší okno spustí vzorek několikrát za jeden stisk (měřeno 5× při 300 ms) |
| `--confirm N` | `1` (vypnuto) | V `--listen` vyžaduje N potvrzení kódu těsně po sobě, než se vypíše. Skutečné tlačítko vysílá opakovaně, šum občas vyplodí jeden rámec s unique id, který debounce nepotlačí — proto `--confirm 3` |
| `--fade-ms N` | `2000` | Doba rozfádění vrstvy po stisku. Vrstva se rozjede z ticha, aby vkradla do toho, co už znějí. `0` = náběh okamžitý |
| `--eager` | vypnuto | Načte všechny samply hned na startu místo až při prvním stisku. Stojí za to paměť — viz [Vrstvy](#vrstvy-fade-a-pamat) |
| `--stop-fade-ms N` | `300` | Doba umčení všeho na `@stopall`. Krátká, protože jde o tlačítko „zhasnout“. `0` usekne napočad, co v sále praskne |
| `--allow-restart` | vypnuto | Povolí akční sloty `@stopall` a `@restart` v mapě (potřebuje root) |
| `--dry-run` | — | Spolu s `--allow-restart` vypíše, co by se spustilo, ale neudělá to |
| `--no-audio` | — | Přeskočí inicializaci zvuku; kódy se stále dekódují a akce vykonají, ale nic se nehraje. Na testování `@stopall`/`@restart` boxem bez zvukové karty |
| `--rf-pin N` | `15` | BCM GPIO linka DATA přijímače (fyzický pin 33) |
| `--listen` | — | Režim pouhého poslechu: vypíše každý detekovaný kód |
| `--learn` | — | Interaktivní registrace tlačítek, zapisuje rovnou do mapy |
| `--simulate` | — | Načítá kódy ze standardního vstupu (stdin) místo RF přijímače |

### Mapování a nahrávání tlačítek

Na boxu B použijte `--learn` — kód se po stisku zapíše do `map.csv` sám:
```bash
sudo systemctl stop sampler
./sampler --box b --learn --lcd-addr off
```
Postup: stiskněte tlačítko, sampler vypíše kód a zeptá se na název samplu.
Prázdný Enter vezme výchozí název (`sample_b_01.wav`, `sample_b_02.wav`, …),
cokoliv jiného se zapíše doslova. `q` ukončí. Každý záznam jde na disk
okamžitě, takže když se v polovině odpojí napájení, zůstane v mapě vše, co
už bylo stisknuto — a další kolo registrace na ni naváže. Tlačítko, které už
v mapě je, se znovu neregistruje, takže se dá pokračovat po výměně baterií.

`--learn` nepotřebuje zesilovač ani zvukovou kartu, takže funguje dřív než
se do krabice něco zapojí. K registrování tlačítek stačí přijímač na GPIO15
**s CS pinem připojeným na 3V3** — volný nebo na GND znamená uspaný modul
a DATA trvale nízká (příznak viz `docs/SCH.md` §4.2).

Starší způsob, když `--learn` nepotřebujete (chcete jen kódy, zapisujete
ručně), je `--listen`:
```bash
./sampler --box b --listen --confirm 3
```
Stiskněte každé tlačítko a zkopírujte vypsaná čísla `code=` do `map.csv`. Formát:
```csv
12200123, sample_b_01.wav
```
Umístěte příslušné soubory (`sample_b_*.wav`) do složky `samples/`.

#### Vrstvy, fade a paměť

Každý slot v mapě je **vrstva**: stisk ji rozfádí od ticha a vzorek se
přehraje **jednou** — pak se sám zastaví. Vrstvy se skládají — stisk
tlačítka B nepřeruší vrstvu A, jen přidá další. Každá má vlastní
`--fade-ms` průběh na vlastním kanálu, takže pět tlačítek dělá
skladbu, která se mění podle toho, co právě zmáčknete. Stisk tlačítka,
jehož vzorek ještě hraje, vrstvu ztlumí (fade-out); tlačítko F pak
zastaví všechno, co právě hraje (`@stopall`).

Kanálů je 20 (`MAX_BUTTONS`), reálně se používá tolik, kolik je slotů
v mapě.

Paměť je tu jediná opravdu úzká věc. SDL_mixer převádí každý vzorek na
formát mixeru hned po načtení, takže **v RAM ho počítá rychlost mixeru,
ne rychlost souboru** — 24 kHz mono stereo je 96 kB/s, 44.1 kHz 176
kB/s. Pěti současně znějícím vrstvám dělá 240 MB proti 480 MB. Proto
mixer běží na 24 kHz a vzorek se načítá až při **prvním stisku**: v mapě
bývá vrstev víc, než se kdy hraje najednou, a načíst všechny znamená
držet v RAM stovky MB. První stisk tak trochu počká, další už ne.
`--eager` to otočí a načte všechno hned (za cenu paměti) — hodí se na
box s dostatkem RAM nebo když chcete hlásit rozbité vzorky při startu.

Na konci se vypíše, co pořád hrálo:
```
layers still playing: 2 [Teskno.wav, Sokol.wav]
```

#### Samply v gitu: Opus, ne WAV

V `samples/` jsou vrstvy uložené jako **mono Opus 24 kHz / 256 kbit/s**
(`samples/*.opus`), dohromady 99 MB. WAV v gitu nejsou a nebyly
  nikdy v této podobě — surové stereo od Matouse má 642 MB a dva
  soubory přesahují GitHubův limit 100 MB na soubor, takže by push
  skončil chybou. Po převodu je největší soubor `Sokol.opus` s 22 MB,
  tedy pod čtvrtinou limitu. Originály zůstávají na disku v `samples/raw/`
  (mimo git) a v záloze na `pesek.com` v `~/ABC38-raw-backup/`.

256 kbit/s je maximum, které `libopus` pro mono přijme. `-b:a 320k` skončí
chybou `The bit rate 320000 bps is unsupported. Please choose a value
between 500 and 256000` a nevytvoří vůbec nic. Ani vyšší kvalita ale není
význam — mixer hraje mono 24 kHz (`MIX_RATE`), takže cokoliv nad 24 kHz
šířku pásma a cokoliv stereo se zahodí ještě před reproduktory.

Důvod, proč to není jen vlastní úsporou místa: `Mix_Chunk` v SDL2_mixer
nemá typový tag, takže `Mix_PlayChannel` umí přehrát jen to, co načetl
`Mix_LoadWAV`. Komprimovaný zvuk jde hrat jedině přes `Mix_PlayMusic` —
a to je jeden globální stream, ne kanál na tlačítko. Vrstvení pěti
tlačítek by tím nešlo udělat.

Proto se Opus převádí na WAV ještě na hostu (`samples-decode.sh`, přes
`make samples`) a `prepare-sd.sh` to spustí taky, takže do SD karty
jde už hotový WAV a **box nepotřebuje ffmpeg** ani nic čekat při startu.
Převod je idempotentní (přeskočí, co je čerstvé) a generované WAV jsou
v `.gitignore`; v gitu zůstávají jen `track?.wav` placeholdery.

```bash
make samples          # samples/*.opus -> samples/*.wav
./samples-decode.sh --force   # přepíše všechny
```

Opačný směr — z původních WAV v `samples/raw/` do Opusu v gitu:

```bash
make encode-samples           # samples/raw/*.wav -> samples/*.opus
BITRATE=192k make encode-samples   # nižší kvalita, ~75 MB
```

Není to součást `make samples`, aby `prepare-sd.sh` při stavbě image
nikdy nepřeváděl 642 MB originálů — staví image z toho, co už v gitu je.
`Sokol(1).wav` se přeskakuje: má stejné md5 jako `Sokol.wav`, do gitu by
jinak přišel jeden zbytečný Opus s 11.6 minuty zvuku navíc.

Do `map.csv` pak pište jména s `.wav`, jak je sampler hraje — stejně
jako dřív, formát mapy se nemění.

#### Speciální kláč: `@stopall`, `@interact` a `@restart`

Slot nemusí mít vzorek. Místo něj může řídit mix, smyčky nebo služby — hodí se
pro tlačítko, které má něco „resetovat“ nebo přepnout:

```csv
5089457, @interact
```

- **`@stopall`** umlčí všechny právě hrající vzorky (one-shot vrstvy). Na boxu A
  je teď na F `@interact`, ale `@stopall` je dál k dispozici.
- **`@interact`** (jen tracker) umlčí hrající vzorky a **přepne `interaction`** —
  osmičku smyček zapne/vypne. Na rozdíl od `@stopall`/`@restart` **nepotřebuje
  root** ani `--allow-restart`, protože sahá jen na vlastní mixer trackera.
- **`@restart`** pustí `systemctl restart` na uvedených jednotkách; jednotky
  odděl mezerou nebo čárkou. V aktuální mapě F `@restart` nemá.

Umčení není okamžité seknutí, ale krátký fade dolů (`--stop-fade-ms`,
default 300 ms) — `Mix_HaltChannel` v půlce tónu v sále praskne. Vrstva
začíná znovu od ticha, když během umčování zmáčkneš tlačítko, které ji
rozjelo; rozfádění umčení zruší, jinak by dotáhlo a zhaslo právě
zapnutou vrstvu.

Bez `--allow-restart` se `@stopall`/`@restart` vynechá a kláč hlásí `not in map`
— aby `--listen` nemohl omylem zhasnout zvuk jen tím, že někdo poslouchá.
`@stopall` je pod stejným zámkem jako `@restart`, ačkoli je samotný
mnohem méně nebezpečný: mapa je důvěryhodný vstup a obojí mění zvuk,
který teď hraje. `sampler.service` běží jako root a `--allow-restart`
má zapnutý, takže na boxu to funguje.

Otestovat, aniž by se něco spustilo, lze přes `--dry-run`, na boxu bez
zvukové karty i přes `--no-audio`:

```bash
echo 5089457 | ./sampler --box b --no-audio --allow-restart --dry-run --simulate
```

##### F na obou boxech
Obě boxy slyší stejný vysílač, takže F udělá to, co má daný box v mapě —
každý box má svůj mix a své sloty. Na boxu A je F `@interact` (přepne smyčky),
na sampleru (Box B/C) obvykle `@stopall` (zhasne hrající vzorky):

```
code=5089457 -> @stopall (S11, #3)
@stopall: 2 vrstv(a) umlceno
@stopall: S01 (Kuchyn_A.wav) ticho
@stopall: S02 (Kuchyn_B.wav) ticho
```

Na bezhlavém boxu je právě tenhle zápis jediná věc, podle čeho se v
journalu pozná, že F zhasl všechno, a ne že jen něco spustil.

**Bezpečnost:** mapa je důvěryhodný vstup, ne data z boxu. Kdo může
zapsat do `map.csv`, může nastartovat cokoliv, co je v mapě uvedeno.

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
*Služba je předkonfigurována pro Box B (`--box b`); vzorový soubor obsahuje `WorkingDirectory=/home/pi/tracker`.*

### Testovací režim na Boxu A
Přijímač SRX882S je na GPIO15 boxu A, ale ten má na kartě tracker. `hw:` je
exkluzivní, takže testovací režim bere zesilovač trackeru a vrací ho zpět:
```bash
sudo ./box-button-test.sh start    # zastaví tracker, pustí sampler na A-E
sudo ./box-button-test.sh status
sudo ./box-button-test.sh stop     # vrátí kartu a nastartuje tracker
tail -f /home/pi/tracker/btn.log   # co se stisklo
```
Režim není služba: běží jako transientní jednotka `box-button-test`, takže
přežije zavření ssh relace a po `stop` po sobě nic nenechá. Kláč F tu
záměrně nefunguje: tento režim zastavil `tracker.service`, aby uvolnil
zvukovou kartu, a kdyby F přidal, zase ho nahodil a testovací sampler by
zůstal bez karty. Běží se s `--lcd-addr off`, protože A nemá displej.

Testy: `tests/test-box-button-test.sh` (31 případů nad falešnými příkazy, bez
GPIO, zvuku a systemd).

#### Čtení 433 MHz do journalu
Na bezhlavém boxu nevidíš obrazovku, takže každý přijatý kód jde do journalu. Podle toho se pozná, jestli tlačítka vůbec něco chytí, i když `map.csv` je ještě prázdná:
```bash
journalctl -t sampler -f      # code=12200123 -> sample_b_01.wav (S01, #7)
journalctl -u sampler -b -n 20
```
Řádek `code=... not in map` znamená, že tlačítko funguje, ale kód v mapě chybí. `VZOREK NENACHRANY` znamená kód v mapě, ale chybí WAV — stisk se i tak vypíše, aby se nezaměnil za mrtvý přijímač.

### Image pro Box B (a burn na SD kartu)
Image se staví ze stejného RPi OS Lite jako Box A, jen s jinou identitou boxu. Provisioning jde do image jako oneshot `box-firstboot.service` a pustí se až na skutečném boxu — QEMU nemá síť, takže by `apt` a build stejně selhaly.
```bash
./qemu_raspi4.sh setup                                        # jen poprvé
sudo ./qemu_raspi4.sh prepare --box B --ip 192.168.8.103 \
     --wifi MOJE_SIT --wifi-pass HESLO
./qemu_raspi4.sh run                                          # zkouška v QEMU
sudo ./qemu_raspi4.sh burn /dev/mmcblk0                       # na kartu
```
Bez `--box` se do image nedostane nic boxového (jen SSH, uživatel, zdrojáky, alsa-utils) — to je výchozí stav pro obyčejné testování.

`--box B` do image přidá: hostname `B`, `dtparam=i2c_arm=on` (LCD na GPIO2/3), `box-provision.sh`, `sampler.service` s `--box b` a `box-sound-restart.sh` restartující sampler.

Kartu lze připravit i rovnou, bez QEMU, přes `prepare-sd.sh` (po `dd` základního image):
```bash
BOX_WIFI_SSID=MOJE_SIT BOX_WIFI_PSK=HESLO sudo ./prepare-sd.sh /dev/mmcblk0 B
```

#### Statická adresa boxu
`box-network.sh` zapisuje profil do `/etc/NetworkManager/system-connections/box-B.nmconnection`. RPi OS vede síť přes NetworkManager, takže `/etc/dhcpcd.conf` by box nečetl.
```bash
sudo ./box-network.sh B                      # 192.168.8.103, bez WiFi (eth0)
BOX_WIFI_SSID=pece BOX_WIFI_PSK=heslo sudo ./box-network.sh B
nmcli con show box-B && ip -4 addr show wlan0
```
Výchozí: box B `192.168.8.103/24`, box A `192.168.8.104`, gateway i DNS `192.168.8.1`. Přepnout jde proměnnými `BOX_IP`, `BOX_PREFIX`, `BOX_GATEWAY`, `BOX_DNS`. Adresa `.102` patří notebooku, ze kterého se image připravuje — nedávat ji boxu.

Prázdné `BOX_IP=` je jiné zadání než nedané: znamená DHCP (`method=auto`), takže se profil vejde i do cizí sítě, kde neznáme subnet. S tímhle zápisem jde mít v `box-network.defaults` obě sítě bez znalosti subnetu kavárny:

```bash
BOX_WIFI_SSID=cafe        # první profil: DHCP, adresu si vezme kavárna
BOX_WIFI_PSK=...
BOX_IP=
BOX_WIFI2_SSID=HUAWEI-B310-C3A0   # druhý profil: statická adresa boxu
BOX_WIFI2_PSK=...                 # (neuvedené BOX_WIFI2_IP = .103 B / .104 A)
```

Obě sítě mají jiné SSID, takže NetworkManager připojí tu, která je v dosahu — box nemusí nikdo přepínat. Druhý profil má vlastní `BOX_WIFI2_IP`, `BOX_WIFI2_GATEWAY` a `BOX_WIFI2_DNS`; když je `BOX_WIFI2_IP` prázdné, jede i druhá síť na DHCP.

#### WiFi profil bez hesla na příkazce
WiFi heslo do repa nepatří (GitHub je veřejný), takže ho `box-network.sh` umí číst z vedlejšího souboru `box-network.defaults`, který je v `.gitignore`:
```bash
cp box-network.defaults.example box-network.defaults
chmod 600 box-network.defaults
$EDITOR box-network.defaults        # BOX_WIFI_SSID=... a BOX_WIFI_PSK=...
sudo ./box-network.sh B            # profil se vytvoří, netřeba nic psát do příkazu
```
Soubor platí jen když existuje, takže bez něj je chování stejné jako dřív (viz `box-network.defaults.example`). Proměnná z prostředí má vždy přednost, takže jednorázově lze přepsat i profil v repu:
```bash
BOX_WIFI_SSID=jinaSit BOX_WIFI_PSK=jineHeslo sudo ./box-network.sh B
```
Pro image to znamená, že `--wifi`/`--wifi-pass` vypustíš, pokud profil leží v `box-network.defaults`:
```bash
sudo ./qemu_raspi4.sh prepare --box B --ip 192.168.8.103
```

> WiFi na Bookworm nekonfiguruj přes `raspi-config` → S1 Wireless LAN — hlásí `there was an error running option S1 Wireless LAN`, protože od Bullseye síť vede NetworkManager a S1 handler je starý. Použij `nmtui`, nebo (lépe) napiš profil do image jako tady.

Dvě věci, které se projeví jinak, než čekáš:
- Keyfile musí mít práva **0600** a vlastníka root — NetworkManager odmítne profil s volně čitelnou WiFi heslem a box skončí bez adresy.
- `ipv4.method` musí být `manual`, jinak DHCP při prvním připojení nabídne jinou adresu a přepíše tvoji.

Testy běží bez sítě i bez NetworkManageru: `./tests/test-box-network.sh`, provisioning nad falešným stromem: `./tests/test-box-provision.sh`.

`./tests/test-sampler-433.sh` staví sampler z hostu a pustí ho proti EV1527 rámcům, které si vyrobí sám, takže jde spustit i bez GPIO a bez zvukové karty. Chybí-li SDL2, skript přeskočí (exit 77) místo toho, aby hlásil falešné chyby. Když je SDL2 jen v cross/sysrootu, stačí ho přimířit:
```bash
ABC38_SYSROOT=/tmp/sdlbuild/sysroot ./tests/test-sampler-433.sh
```

Převod samplů má test bez ffmpeg — `FFMPEG` se přesměruje na falešný
skript, takže jde ověřit logika, ne samotný převod. Oba směry:
```bash
./tests/test-samples-decode.sh   # Opus -> WAV (to, co jde na box)
./tests/test-samples-encode.sh   # raw WAV -> Opus (to, co je v gitu)
```

---

## Hardware / BOM (Česky)
Kompletní požadavky na hardware a nákupní seznam naleznete v souboru [`HW.md`](HW.md). 
Systém běží na sestavě dvou zařízení (vše Raspberry Pi 4, 8 GB). Box A je tracker s webkamerou, zatímco Box B je bezdrátový spouštěč samplů. Každý box má vlastní USB zvukovou kartu (AXAGON ADA-17), panelové audio výstupy a interní reproduktor se zesilovačem.
Kompletní schémata zapojení jsou k dispozici v [`docs/SCH.md`](docs/SCH.md).

---

## Řešení problémů

### Kamera na Termuxu
Android/Termux neposkytuje V4L2 (`/dev/video0`), takže `build_termux.sh` staví tracker s `HAVE_V4L2=0` — kamera se neotevře a tracker běží jen jako zvuk + RF tlačítka. Na Linuxu (box A, laptop) kameru obsluhuje V4L2 + libjpeg-turbo a žádné OpenCV není potřeba.

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

### "Could not open video capture device" na Box A
Webkamera (V4L2) má single-open: `/dev/video0` drží právě jeden proces. Běží-li
služba, ruční spuštění trackeru selže. Před ručním během službu zastavte:
```bash
sudo systemctl stop tracker
./tracker            # nebo ./tracker --headless
sudo systemctl start tracker
```

---

## Struktura projektu
- `main.c` — Zdrojový kód aplikace Tracker (barevné HSV blob sledování dvou koulí, kalibrace perspektivy + učení barev, 8 smyček s přepínačem `@interact`, sloučený RF sampler)
- `buttons.c` / `buttons.h` — RF engine: EV1527 dekodér, `map.csv`, vrstvy vzorků, akce `@stopall`/`@interact`/`@restart` (sdílí tracker i sampler)
- `sampler.c` — Zdrojový kód aplikace Sampler (EV1527 RF + SDL2_mixer + volitelně LCD)
- `Makefile` — Systém sestavení
- `map.csv.example` — Šablona pro mapování RF kódů na zvukové stopy
- `build_termux.sh` — Skript pro nastavení v prostředí Termux
- `sampler.service` — systemd služba pro automatický start Boxu B
- `box-button-test.sh` — Testovací režim: sampler na tlačítka A–E přímo na Boxu A
  (transientní jednotka, bere trackeru zvukovač a vrací ho)
- `docs/` — Schémata, manuály a generátory PDF
- `HW.md` / `nakup.txt` / `dostupnost.txt` — Seznam hardwaru a součástek (česky)

## Verze
0.5.0
