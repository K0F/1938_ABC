// buttons.c — see buttons.h. Trimmed from sampler.c for the merged tracker.
#include "buttons.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <sys/wait.h>
#include <unistd.h>

// systemctl returns 5 when the unit is not on this box. The map is the same on
// both boxes but the units are split (tracker.service only on A, sampler.service
// only on B), so pressing F on the wrong box is not an error.
#define EXIT_UNIT_NOT_FOUND 5

static uint64_t nowUs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)ts.tv_nsec / 1000ull;
}

int ButtonEngine::classifyShort(int us) const {
    return us >= 6 * teUs_ / 10 && us <= 16 * teUs_ / 10;
}

int ButtonEngine::classifyBit(int us) const {
    if (us >= 6 * teUs_ / 10 && us <= 16 * teUs_ / 10) return 0;
    if (us >= 20 * teUs_ / 10 && us <= 40 * teUs_ / 10) return 1;
    return -1;
}

bool ButtonEngine::isActionSlot(int i) const {
    return !slots_[i].restartUnits.empty() || slots_[i].stopAll ||
           slots_[i].interact;
}

int ButtonEngine::loadMap() {
    FILE* f = fopen(mapPath_.c_str(), "r");
    if (!f) {
        fprintf(stderr, "Warning: cannot open map '%s'\n", mapPath_.c_str());
        return 0;
    }
    char line[512];
    int n = 0;
    while (fgets(line, sizeof(line), f)) {
        char* p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;

        char* end = NULL;
        unsigned long code = strtoul(p, &end, 10);
        p = end;
        while (*p == ' ' || *p == '\t' || *p == ',') p++;

        int k = 0;
        char name[256];
        while (*p && *p != '\n' && *p != '\r') {
            if (*p == ' ' || *p == '\t') {
                while (*p == ' ' || *p == '\t') p++;
                if (*p && *p != '\n' && *p != '\r') name[k++] = ' ';
                continue;
            }
            name[k++] = *p++;
        }
        name[k] = '\0';
        while (k > 0 && (name[k - 1] == ' ')) name[--k] = '\0';
        if (k == 0) continue;

        if (n >= BUTTONS_MAX_SLOTS) {
            fprintf(stderr,
                    "Warning: map '%s' has more than %d entries; ignoring %lu\n",
                    mapPath_.c_str(), BUTTONS_MAX_SLOTS, code);
            continue;
        }
        slots_[n].restartUnits.clear();
        slots_[n].stopAll = 0;
        slots_[n].interact = 0;
        // An action slot is recognised by its leading @, not by a known
        // directive: a typo (@stopal) would otherwise be taken silently as a
        // sample name and the map would look fine while F did nothing.
        if (name[0] == '@') {
            std::string units = std::string(name);
            for (size_t i = 0; i < units.size(); i++)
                if (units[i] == ',') units[i] = ' ';
            size_t pos = 0;
            while (pos < units.size()) {
                while (pos < units.size() && units[pos] == ' ') pos++;
                size_t end = pos;
                while (end < units.size() && units[end] != ' ') end++;
                if (end == pos) break;
                std::string word = units.substr(pos, end - pos);
                if (word == "@stopall") {
                    slots_[n].stopAll = 1;
                } else if (word == "@interact") {
                    slots_[n].interact = 1;
                } else if (word == "@restart") {
                    std::string rest = units.substr(end);
                    size_t b = rest.find_first_not_of(' ');
                    slots_[n].restartUnits =
                        b == std::string::npos ? "" : rest.substr(b);
                    break;
                } else if (word[0] == '@') {
                    fprintf(stderr,
                            "Warning: map '%s': unknown directive '%s' on "
                            "code %lu (expected @stopall, @interact or "
                            "@restart)\n",
                            mapPath_.c_str(), word.c_str(), code);
                }
                pos = end;
            }
            // @stopall/@restart poke systemd, so they need --allow-restart
            // (root). @interact only touches our own mixer, so it is always
            // allowed.
            bool needsRoot =
                slots_[n].stopAll || !slots_[n].restartUnits.empty();
            if (needsRoot && !restartAllowed_) {
                fprintf(stderr,
                        "Warning: map '%s' wants an action slot (@stopall/"
                        "@restart), but --allow-restart was not given; "
                        "code %lu is ignored\n",
                        mapPath_.c_str(), code);
                continue;
            }
            if (!slots_[n].stopAll && !slots_[n].interact &&
                slots_[n].restartUnits.empty()) {
                fprintf(stderr,
                        "Warning: map '%s': slot '%s' on code %lu is an action "
                        "slot with no known directive; code %lu is ignored\n",
                        mapPath_.c_str(), name, code, code);
                continue;
            }
        }

        slots_[n].code = (uint32_t)code;
        slots_[n].channel = channelBase_ + n;
        slots_[n].file = name;
        slots_[n].chunk = NULL;
        slots_[n].lastUs = 0;
        slots_[n].fadeStartUs = 0;
        slots_[n].fadeFromVol = 0;
        slots_[n].fadingOut = 0;
        slots_[n].loadTried = 0;
        n++;
    }
    fclose(f);
    numSlots_ = n;
    fprintf(stdout, "map: %d slot(s) from %s\n", numSlots_, mapPath_.c_str());
    fflush(stdout);
    return numSlots_;
}

bool ButtonEngine::loadSample(int i) {
    if (slots_[i].chunk) return true;
    if (slots_[i].loadTried) return false;
    slots_[i].loadTried = 1;
    std::string path = samplesDir_ + "/" + slots_[i].file;
    slots_[i].chunk = Mix_LoadWAV(path.c_str());
    if (!slots_[i].chunk)
        fprintf(stderr, "Warning: cannot load sample '%s'\n", path.c_str());
    return slots_[i].chunk != NULL;
}

void ButtonEngine::startLayer(int i) {
    Mix_HaltChannel(slots_[i].channel);
    // 0 = silent, then fadesTick() ramps it up.
    Mix_Volume(slots_[i].channel, fadeUs_ ? 0 : MIX_MAX_VOLUME);
    Mix_PlayChannel(slots_[i].channel, slots_[i].chunk, 0);
    slots_[i].fadeStartUs = nowUs();
    // A fresh press cancels any @stopall fade-out, otherwise fadesTick would
    // keep dropping the volume of the just-started layer.
    slots_[i].fadingOut = 0;
    slots_[i].fadeFromVol = 0;
}

void ButtonEngine::fadeOutLayer(int i) {
    if (!audioOk_) return;
    uint64_t t = nowUs();
    if (!Mix_Playing(slots_[i].channel)) return;
    if (!stopFadeUs_) {
        Mix_HaltChannel(slots_[i].channel);
        slots_[i].fadeStartUs = 0;
        slots_[i].fadingOut = 0;
        return;
    }
    slots_[i].fadeFromVol = (uint64_t)Mix_Volume(slots_[i].channel, -1);
    slots_[i].fadeStartUs = t;
    slots_[i].fadingOut = 1;
}

int ButtonEngine::stopAllLayers() {
    if (!audioOk_) return 0;
    uint64_t t = nowUs();
    int stopped = 0;
    for (int i = 0; i < numSlots_; i++) {
        if (!Mix_Playing(slots_[i].channel)) continue;
        stopped++;
        if (!stopFadeUs_) {
            Mix_HaltChannel(slots_[i].channel);
            slots_[i].fadeStartUs = 0;
            slots_[i].fadingOut = 0;
            continue;
        }
        slots_[i].fadeFromVol = (uint64_t)Mix_Volume(slots_[i].channel, -1);
        slots_[i].fadeStartUs = t;
        slots_[i].fadingOut = 1;
    }
    return stopped;
}

void ButtonEngine::fadesTick() {
    if (!audioOk_) return;
    uint64_t t = nowUs();
    for (int i = 0; i < numSlots_; i++) {
        if (!slots_[i].fadeStartUs) continue;
        if (!Mix_Playing(slots_[i].channel)) {
            slots_[i].fadeStartUs = 0;
            slots_[i].fadingOut = 0;
            continue;
        }
        uint64_t el = t - slots_[i].fadeStartUs;

        if (slots_[i].fadingOut) {
            if (el >= stopFadeUs_) {
                Mix_Volume(slots_[i].channel, 0);
                Mix_HaltChannel(slots_[i].channel);
                fprintf(stdout, "@stopall: S%02d (%s) ticho\n", i + 1,
                        slots_[i].file.c_str());
                fflush(stdout);
                slots_[i].fadeStartUs = 0;
                slots_[i].fadingOut = 0;
                continue;
            }
            uint64_t v = slots_[i].fadeFromVol *
                         (stopFadeUs_ - el) / stopFadeUs_;
            Mix_Volume(slots_[i].channel, (int)v);
            continue;
        }

        if (el >= fadeUs_) {
            Mix_Volume(slots_[i].channel, MIX_MAX_VOLUME);
            slots_[i].fadeStartUs = 0;
            continue;
        }
        int v = (int)((uint64_t)MIX_MAX_VOLUME * el / fadeUs_);
        Mix_Volume(slots_[i].channel, v);
    }
}

// Action slot: runs `systemctl restart` on the units from the map. system() is
// deliberately avoided — argv is passed without a shell so a unit name cannot
// be mangled. The map is a trusted input owned by the box admin.
void ButtonEngine::doRestart(const std::string& units, int slotIdx) {
    std::string rest = units;
    while (!rest.empty() && rest[0] == ' ') rest.erase(rest.begin());
    std::vector<std::string> list;
    std::string cur;
    for (size_t i = 0; i <= rest.size(); i++) {
        if (i == rest.size() || rest[i] == ' ') {
            if (!cur.empty()) { list.push_back(cur); cur.clear(); }
        } else {
            cur += rest[i];
        }
    }
    if (list.empty()) {
        fprintf(stderr, "Warning: @restart slot S%02d has no units\n",
                slotIdx + 1);
        return;
    }
    for (size_t i = 0; i < list.size(); i++) {
        fprintf(stdout, "code=%u -> @restart %s\n", slots_[slotIdx].code,
                list[i].c_str());
        fflush(stdout);
        if (dryRun_) {
            fprintf(stdout, "@restart %s: dry-run, not run\n", list[i].c_str());
            fflush(stdout);
            continue;
        }
        if (geteuid() != 0) {
            fprintf(stdout, "@restart %s: needs root, skipped\n",
                    list[i].c_str());
            fflush(stdout);
            continue;
        }
        pid_t pid = fork();
        if (pid == 0) {
            execlp("systemctl", "systemctl", "restart", "--",
                   list[i].c_str(), (char*)NULL);
            _exit(127);
        } else if (pid > 0) {
            int status = 0;
            waitpid(pid, &status, 0);
            if (WIFEXITED(status) && WEXITSTATUS(status) == 127) {
                fprintf(stdout, "@restart %s: systemctl not found\n",
                        list[i].c_str());
            } else if (WIFEXITED(status) &&
                       WEXITSTATUS(status) == EXIT_UNIT_NOT_FOUND) {
                fprintf(stdout, "@restart %s: jednotka na tomhle boxu není "
                                "(jednotka je na druhém boxu?)\n",
                        list[i].c_str());
            } else if (WIFEXITED(status) && WEXITSTATUS(status) != 0) {
                fprintf(stdout, "@restart %s: rc=%d\n", list[i].c_str(),
                        WEXITSTATUS(status));
            }
            fflush(stdout);
        } else {
            perror("fork");
        }
    }
}

void ButtonEngine::onCode(uint32_t code) {
    for (int i = 0; i < numSlots_; i++) {
        if (slots_[i].code != code) continue;
        uint64_t t = nowUs();
        if (slots_[i].lastUs && t - slots_[i].lastUs < debounceUs_) return;
        // The timestamp is written even without a sample, otherwise a single
        // press would spam the journal with dozens of lines.
        slots_[i].lastUs = t;
        pressCount_++;
        if (isActionSlot(i)) {
            const char* act = slots_[i].interact ? "@interact"
                            : (slots_[i].stopAll ? "@stopall" : "@restart");
            fprintf(stdout, "code=%u -> %s (S%02d, #%llu)\n", code, act,
                    i + 1, (unsigned long long)pressCount_);
            fflush(stdout);
            // Order matters: silence the one-shot layers first, then signal the
            // tracker (@interact) or restart units.
            if (slots_[i].stopAll || slots_[i].interact) {
                int n = stopAllLayers();
                if (slots_[i].stopAll) {
                    fprintf(stdout, "@stopall: %d vrstv(a) umlceno\n", n);
                    fflush(stdout);
                }
                if (slots_[i].interact) {
                    interactFlag_ = 1;
                    fprintf(stdout, "@interact: %d vzorku umlceno, "
                                    "prepinam interaction\n", n);
                    fflush(stdout);
                }
            }
            if (!slots_[i].restartUnits.empty())
                doRestart(slots_[i].restartUnits, i);
            return;
        }
        if (!audioOk_) {
            fprintf(stdout, "code=%u -> %s (S%02d, #%llu) [no-audio]\n",
                    code, slots_[i].file.c_str(), i + 1,
                    (unsigned long long)pressCount_);
            fflush(stdout);
            return;
        }
        // Press while this layer plays and is not already fading out -> fade it
        // out instead of restarting it from the top.
        if (Mix_Playing(slots_[i].channel) && !slots_[i].fadingOut) {
            fadeOutLayer(i);
            fprintf(stdout, "code=%u -> fadeout %s (S%02d, #%llu)\n",
                    code, slots_[i].file.c_str(), i + 1,
                    (unsigned long long)pressCount_);
            fflush(stdout);
            return;
        }
        if (!loadSample(i)) {
            fprintf(stdout, "code=%u -> %s (S%02d, #%llu) VZOREK NENACHRANY\n",
                    code, slots_[i].file.c_str(), i + 1,
                    (unsigned long long)pressCount_);
            fflush(stdout);
            return;
        }
        startLayer(i);
        fprintf(stdout, "code=%u -> %s (S%02d, #%llu) fade %llums, one-shot\n",
                code, slots_[i].file.c_str(), i + 1,
                (unsigned long long)pressCount_,
                (unsigned long long)(fadeUs_ / 1000ull));
        fflush(stdout);
        return;
    }
    // Not in the map: optional legacy F restart (default off in the tracker so
    // the map's @stopall wins), otherwise just say so.
    if (resetCode_ && code == resetCode_) {
        fprintf(stdout, "code=%u -> restart (reset-code)\n", code);
        fflush(stdout);
        restartFlag_ = 1;
        return;
    }
    fprintf(stderr, "code=%u not in map\n", code);
}

void ButtonEngine::decoderPush(uint64_t evUs, int rising) {
    Ev1527Decoder& d = dec_;
    if (d.lastUs && evUs > d.lastUs) {
        int durn = (int)(evUs - d.lastUs);
        if (rising) {
            if (durn >= 15 * teUs_) {
                if (d.haveHigh && classifyShort(d.highUs)) {
                    d.state = 1;
                    d.bitCount = 0;
                    d.code = 0;
                } else {
                    d.state = 0;
                }
                d.haveHigh = 0;
            } else if (durn >= 4 * teUs_) {
                d.state = 0;
                d.bitCount = 0;
                d.haveHigh = 0;
            } else if (d.state == 1 && d.haveHigh) {
                int b = classifyBit(d.highUs);
                if (b >= 0) {
                    d.code = (d.code << 1) | (uint32_t)b;
                    d.bitCount++;
                    d.haveHigh = 0;
                    if (d.bitCount == 24) {
                        std::lock_guard<std::mutex> lock(pendingMutex_);
                        pending_.push_back(d.code);
                        d.state = 0;
                        d.bitCount = 0;
                    }
                } else {
                    d.state = 0;
                    d.bitCount = 0;
                    d.haveHigh = 0;
                }
            }
        } else {
            d.highUs = durn;
            d.haveHigh = 1;
        }
    }
    d.lastUs = evUs;
}

void ButtonEngine::pushEvent(uint64_t evUs, int rising) {
    decoderPush(evUs, rising);
}

int ButtonEngine::processPending() {
    std::vector<uint32_t> batch;
    {
        std::lock_guard<std::mutex> lock(pendingMutex_);
        if (pending_.empty()) return 0;
        batch.swap(pending_);
    }
    for (uint32_t code : batch) onCode(code);
    return (int)batch.size();
}

bool ButtonEngine::takeRestart() {
    if (!restartFlag_) return false;
    restartFlag_ = 0;
    return true;
}

bool ButtonEngine::takeInteract() {
    if (!interactFlag_) return false;
    interactFlag_ = 0;
    return true;
}
