#ifndef AUDIO_TAP_BRIDGE_H
#define AUDIO_TAP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#define SAT_AUDIO_FIFO_CAPACITY_FRAMES 32768u
#define SAT_AUDIO_FIFO_CHANNEL_COUNT 2u

/// A bounded single-producer/single-consumer FIFO for stereo Float32 PCM.
/// Sample storage is atomic so the input and output device callbacks never
/// participate in a C data race. The callbacks do not allocate or lock.
typedef struct SATAudioFIFO SATAudioFIFO;

SATAudioFIFO* SATAudioFIFOCreate(void);
void SATAudioFIFODestroy(SATAudioFIFO* fifo);

void SATAudioFIFOClear(SATAudioFIFO* fifo);

/// Writes as many complete stereo frames as fit and returns that count.
uint32_t SATAudioFIFOWrite(
    SATAudioFIFO* fifo,
    const float* interleavedSamples,
    uint32_t frameCount
);

/// Reads available frames, fills any shortfall with silence, and returns the
/// number of source frames consumed.
uint32_t SATAudioFIFORead(
    SATAudioFIFO* fifo,
    float* interleavedSamples,
    uint32_t frameCount
);

uint32_t SATAudioFIFOAvailableFrames(const SATAudioFIFO* fifo);
void SATAudioFIFOGetStats(
    const SATAudioFIFO* fifo,
    uint64_t* framesWritten,
    uint64_t* framesRead,
    uint64_t* droppedFrames,
    uint64_t* underflowFrames
);

#define SAT_FIFO_READER_MAXIMUM_CROSSFADE_FRAMES 1024u
#define SAT_FIFO_READER_MAXIMUM_SPLICE_SEARCH_FRAMES 2048u

/// How the playback side of a SATAudioFIFO keeps latency low without clicks.
/// All values are in frames.
typedef struct SATFIFOReaderConfiguration {
    /// Audio to buffer before playback starts. The reader never aims lower than
    /// two callbacks, a fade, and the splice search range.
    uint32_t initialLatencyFrames;
    /// Bounds for the latency target. A dropout doubles the target, and a long
    /// stretch of clean playback lowers it by a quarter.
    uint32_t minimumLatencyFrames;
    uint32_t maximumLatencyFrames;
    /// Fade in when playback starts and fade out when capture runs dry.
    uint32_t fadeFrames;
    /// Crossfade for a latency splice, limited to one callback.
    uint32_t crossfadeFrames;
    /// Range searched for the splice point that best matches the audio. The
    /// average buffer level may also stray this far from the target unspliced.
    uint32_t spliceSearchFrames;
    /// Playback over which the buffer level is averaged before correcting it.
    uint32_t checkFrames;
    /// Clean playback needed before the latency target is lowered.
    uint64_t relaxFrames;
} SATFIFOReaderConfiguration;

typedef struct SATFIFOReaderStats {
    /// Output frames that came from the FIFO.
    uint64_t framesPlayed;
    /// Output frames of silence while buffering.
    uint64_t silentFrames;
    /// Times capture ran dry and playback faded out.
    uint64_t dropouts;
    /// Latency corrections, and the frames they skipped or repeated.
    uint64_t splices;
    uint64_t framesSkipped;
    uint64_t framesRepeated;
    uint32_t latencyTargetFrames;
} SATFIFOReaderStats;

/// Reads a SATAudioFIFO for the playback callback. It buffers to a latency target
/// before playing, fades out instead of cutting off when capture runs dry, and
/// moves the buffer level back to the target with crossfaded splices aligned to
/// the audio, so the capture and playback clocks may differ. Only the playback
/// callback reads; stats may be read from any thread.
typedef struct SATFIFOReader SATFIFOReader;

SATFIFOReader* SATFIFOReaderCreate(void);
void SATFIFOReaderDestroy(SATFIFOReader* reader);

/// Starts over, including stats. Pass NULL to keep the previous configuration.
/// Call only while the playback callback is stopped.
void SATFIFOReaderReset(SATFIFOReader* reader, const SATFIFOReaderConfiguration* configuration);

/// Fills all `frameCount` stereo frames.
void SATFIFOReaderRead(
    SATFIFOReader* reader,
    SATAudioFIFO* fifo,
    float* interleavedSamples,
    uint32_t frameCount
);

void SATFIFOReaderGetStats(const SATFIFOReader* reader, SATFIFOReaderStats* stats);

#endif
