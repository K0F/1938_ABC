# Multi-Track Audio Tracker & RF Sampler

Tento repozitář obsahuje dvě hlavní aplikace vytvořené pro interaktivní zvukovou instalaci:
1. **Tracker (Box A)**: Přehrávač s amplitudovou modulací více stop založený na webkameře. Sledované barevné míčky ovládají hlasitost zvukových smyček s korekcí perspektivy.
2. **Sampler (Box B)**: Bezdrátový sampler, ve kterém 433 MHz RF tlačítka spouští jednorázové zvukové samply.

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

### Headless režim (Box A v produkci)
Box A běží bez okna a bez X — grafiku nepotřebuje, jen kameru a zvuk. Služba běží jako uživatel `pi`:
```bash
./tracker --headless 1  # bez okna, 1 míček; vstup přes systemd
```
```bash
sudo cp tracker.service /etc/systemd/system/
sudo systemctl enable --now tracker
journalctl -t tracker -f   # logy do journalu
```
Okenný režim zůstává pro kalibraci (přetáhnutí rohů, klávesa `S`). Bez `calib.txt` tracker používá celý snímek, takže první kalibraci udělejte ještě s monitorem přes HDMI.

#### Autostart po restartu
`tracker.service` je `enabled` — po každém restartu boxu se tracker rozjede sám, bez monitoru a bez přihlášení. Když při startu ještě není kamera, služba zkusí znovu po 2 s; limit restartu je vypnutý (`StartLimitIntervalSec=0`), jinak by ji po pěti rychlých pokusech systemd zabil a tracker by zůstal tichý do ručního zásahu.
```bash
systemctl is-enabled tracker              # enabled
systemctl status tracker
journalctl -u tracker -b | head           # "tracker vX.Y.Z start: headless, 640x480, ..."
```

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
displej. Snímek kamery 640x480 se v něm vejde svisle a do stran je pillarbox
(4:3 na 16:9 bez zkreslení míčů) — řeší to tracker sám, viz `main.c`.

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
vždy a přežije i restarty trackera. Stojí to zhruba dvě jádra CPU (kamera,
OpenCV i kreslení) — na boxu, kde má grafika vykonávat práci, to vypnout lze
proměnnou:
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
cat /tmp/box-console-tracker.log      # výstup trackera (začátek: "okno 1920x1080, snímek 640x480 x2.25 na (240,0)")
```
Relace běží, dokud tracker jede; když spadne dvakrát po sobě za dvě sekundy,
zvedne ho cyklus v `box-console.xinit`. Když se nedaří (chybí binárka, X bez
GLX), relace skončí a na TV zůstane login prompt, ať u něj člověk může —
jinak by TV blikala bez zjevu. Stejně po třech rychlých restartech skončí
profil: `box-console: X relace padá pořád dokola`. Po opravě `rm
/tmp/.box-console.fails` nebo `box-console.sh off && on`.

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
| `S` | Uloží kalibraci do `calib.txt` |
| `R` | Resetuje rohy na celý obraz |

---

## 2. Sampler (Box B)

Sampler funguje jako samostatná bezdrátová spouštěcí jednotka. Využívá 433 MHz RF přijímač pro příjem signálů z 10 bezdrátových tlačítek (Solight 1L67T, protokol EV1527) a přehrává jednorázové zvukové samply přes `SDL2_mixer`. Také může volitelně aktualizovat stav úderů na 16×2 I2C displeji.

- RF kódy jsou dekódovány nativně na **GPIO15** (fyzický pin 33) pomocí interního EV1527 dekodéru přes `libgpiod` (není potřeba rc-switch/wiringPi).
- Samply jsou jednorázové a spouští se znovu při každém stisknutí.

> **Než připojíš tlačítko:** pin CS (4) SRX882S patří na 3V3. Volně ponechaný
> nebo na GND uspí modul — DATA pak trvale nízká, na GPIO žádné hrany a
> tlačítko vypadá jako mrtvé i s novou baterií. Podrobně `docs/SCH.md` §4.2.
>
> Tlačítko vysílá opakovaně, dokud je držené. Při výchozím debounce 300 ms se
> jeden stisk vypíše až 16×; v režimu hraní je proto vhodné `--debounce-ms 5000`.
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
| `--map SOUBOR` | `mapa.csv` | Soubor mapující kódy na samply |
| `--samples-dir SLOŽKA` | `samples` | Složka obsahující WAV soubory |
| `--lcd-addr HEX` | `0x27` | I2C adresa PCF8574 displeje, nebo `off` |
| `--te-us N` | `320` | Základní časování EV1527 v µs (nutno doladit pro každé tlačítko) |
| `--debounce-ms N` | `300` | Časové okno pro debounce každého tlačítka |
| `--rf-pin N` | `15` | BCM GPIO linka DATA přijímače (fyzický pin 33) |
| `--listen` | — | Režim pouhého poslechu: vypíše každý detekovaný kód |
| `--learn` | — | Interaktivní registrace tlačítek, zapisuje rovnou do mapy |
| `--simulate` | — | Načítá kódy ze standardního vstupu (stdin) místo RF přijímače |

### Mapování a nahrávání tlačítek

Na boxu B použijte `--learn` — kód se po stisku zapíše do `mapa.csv` sám:
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
./sampler --box b --listen
```
Stiskněte každé tlačítko a zkopírujte vypsaná čísla `code=` do `mapa.csv`. Formát:
```csv
12200123, sample_b_01.wav
```
Umístěte příslušné soubory (`sample_b_*.wav`) do složky `samples/`.

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

#### Čtení 433 MHz do journalu
Na bezhlavém boxu nevidíš obrazovku, takže každý přijatý kód jde do journalu. Podle toho se pozná, jestli tlačítka vůbec něco chytí, i když `mapa.csv` je ještě prázdná:
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

---

## Hardware / BOM (Česky)
Kompletní požadavky na hardware a nákupní seznam naleznete v souboru [`HW.md`](HW.md). 
Systém běží na sestavě dvou zařízení (vše Raspberry Pi 4, 8 GB). Box A je tracker s webkamerou, zatímco Box B je bezdrátový spouštěč samplů. Každý box má vlastní USB zvukovou kartu (AXAGON ADA-17), panelové audio výstupy a interní reproduktor se zesilovačem.
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

### "Could not open video capture device" na Box A
Webkamera (V4L2) má single-open: `/dev/video0` drží právě jeden proces. Běží-li
služba, ruční spuštění trackeru selže. Před ručním během službu zastavte:
```bash
sudo systemctl stop tracker
./tracker            # nebo ./tracker --headless 1
sudo systemctl start tracker
```

---

## Struktura projektu
- `main.c` — Zdrojový kód aplikace Tracker
- `sampler.c` — Zdrojový kód aplikace Sampler (EV1527 RF + SDL2_mixer + volitelně LCD)
- `Makefile` — Systém sestavení
- `mapa.csv.example` — Šablona pro mapování RF kódů na zvukové stopy
- `build_termux.sh` — Skript pro nastavení v prostředí Termux
- `sampler.service` — systemd služba pro automatický start Boxu B
- `docs/` — Schémata, manuály a generátory PDF
- `HW.md` / `nakup.txt` / `dostupnost.txt` — Seznam hardwaru a součástek (česky)

## Verze
0.5.0
