#ifndef BUTTONS_H
#define BUTTONS_H

// buttons.h — 433 MHz RF sample-button engine for the tracker (Box A).
//
// The tracker used to be a standalone camera app and the sampler a separate
// process on the same box. They fought over the audio card and the SRX882S
// receiver on GPIO15. This module folds the sampler's button half into the
// tracker so one process owns both: the tracker keeps playing its ball-mixed
// loops on channels [0, N_LOOP), and each RF button mapped in map.csv plays a
// fade-in one-shot on top of them on channels [channelBase, channelBase+20).
//
// It is a trimmed copy of sampler.c's decoding/mapping/audio-layer code
// (sampler.c stays as the standalone binary for Box B). The EV1527 decoder,
// map parsing, fade tick and @stopall/@restart dispatch are identical so the
// journal reads the same on both boxes.

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include <SDL2/SDL_mixer.h>

#define BUTTONS_MAX_SLOTS 20

struct ButtonSlot {
    uint32_t code = 0;
    int channel = 0;
    std::string file;
    Mix_Chunk* chunk = nullptr;
    uint64_t lastUs = 0;
    // Slot with restartUnits != "" is an action slot: instead of playing a
    // sample it runs `systemctl restart` on the listed units.
    std::string restartUnits;
    // Action slot may also carry @stopall: fade every playing sample layer to
    // silence before the restart.
    int stopAll = 0;
    // @interact: stop every playing one-shot layer and signal the tracker to
    // toggle its interactive part (button F). Needs no root, unlike
    // @stopall/@restart.
    int interact = 0;
    // Fade-in start (0 = not playing). Mix_Volume is per channel, so each
    // layer fades independently.
    uint64_t fadeStartUs = 0;
    // Fade-out (@stopall) runs the other way: from the current volume down.
    uint64_t fadeFromVol = 0;
    int fadingOut = 0;
    // 1 = Mix_LoadWAV already tried (even if it failed, so a missing WAV is
    // not retried and spammed into the journal on every press).
    int loadTried = 0;
};

struct Ev1527Decoder {
    int state = 0;
    int bitCount = 0;
    uint32_t code = 0;
    uint64_t lastUs = 0;
    int highUs = 0;
    int haveHigh = 0;
};

class ButtonEngine {
public:
    // ── configuration (set before loadMap / play) ──
    void setBoxLetter(char b) { boxLetter_ = b; }
    void setMapPath(const char* p) { mapPath_ = p; }
    void setSamplesDir(const char* d) { samplesDir_ = d; }
    void setTeUs(int us) { teUs_ = us; }
    void setDebounceMs(int ms) { debounceUs_ = (uint64_t)ms * 1000ull; }
    void setFadeMs(int ms) { fadeUs_ = (uint64_t)ms * 1000ull; }
    void setStopFadeMs(int ms) { stopFadeUs_ = (uint64_t)ms * 1000ull; }
    void setAllowRestart(bool on) { restartAllowed_ = on; }
    void setDryRun(bool on) { dryRun_ = on; }
    // Mixer opened by the caller (false = --no-audio: decode and act, but play
    // nothing). Channel base = first SDL_mixer channel available for samples;
    // the tracker puts its 7 loop channels before it.
    void setAudioOk(bool on) { audioOk_ = on; }
    void setChannelBase(int base) { channelBase_ = base; }
    // Optional legacy behaviour: this code restarts the service (the old
    // tracker button F). Default 0 = off, so map.csv wins (F = @stopall).
    void setResetCode(uint32_t code) { resetCode_ = code; }

    // ── lifecycle ──
    // Parse map.csv. Returns the number of slots loaded.
    int loadMap();
    int slotCount() const { return numSlots_; }
    const ButtonSlot& slot(int i) const { return slots_[i]; }
    bool isActionSlot(int i) const;

    // ── input ──
    // Decode one GPIO edge (called from the RF thread). Complete 24-bit
    // frames are queued and dispatched later by processPending().
    void pushEvent(uint64_t evUs, int rising);
    // Drain queued codes and dispatch each. Returns how many were handled.
    int processPending();
    // Dispatch a code directly (desktop --simulate, tests).
    void onCode(uint32_t code);

    // ── per-frame housekeeping ──
    void fadesTick();

    // True once (and clears) if setResetCode matched a received code.
    bool takeRestart();
    // True once (and clears) when an @interact slot was pressed. The tracker
    // uses this to toggle its interactive part (button F).
    bool takeInteract();

private:
    bool loadSample(int i);
    void startLayer(int i);
    void fadeOutLayer(int i);
    int stopAllLayers();
    void doRestart(const std::string& units, int slotIdx);
    int classifyShort(int us) const;
    int classifyBit(int us) const;
    void decoderPush(uint64_t evUs, int rising);

    char boxLetter_ = 'A';
    std::string mapPath_ = "map.csv";
    std::string samplesDir_ = "samples";
    int teUs_ = 320;
    uint64_t debounceUs_ = 2000000ull;
    uint64_t fadeUs_ = 2000000ull;
    uint64_t stopFadeUs_ = 300000ull;
    bool restartAllowed_ = false;
    bool dryRun_ = false;
    bool audioOk_ = false;
    int channelBase_ = 0;
    uint32_t resetCode_ = 0;
    uint64_t pressCount_ = 0;
    int restartFlag_ = 0;
    int interactFlag_ = 0;

    ButtonSlot slots_[BUTTONS_MAX_SLOTS];
    int numSlots_ = 0;

    Ev1527Decoder dec_;
    std::vector<uint32_t> pending_;
    std::mutex pendingMutex_;
};

#endif
