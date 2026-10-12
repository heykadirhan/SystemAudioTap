#include "AudioTapBridge.h"

#include <math.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/// A repeat splice reads audio the reader already played. It stays clear of the
/// writer as long as the writer adds fewer than this many frames at once.
#define SAT_FIFO_READER_WRITER_CLEARANCE_FRAMES 8192u

struct SATAudioFIFO {
    _Atomic(uint64_t) readFrame;
    _Atomic(uint64_t) writeFrame;
    _Atomic(uint64_t) totalFramesWritten;
    _Atomic(uint64_t) totalFramesRead;
    _Atomic(uint64_t) droppedFrames;
    _Atomic(uint64_t) underflowFrames;
    _Atomic(uint32_t) sampleBits[
        SAT_AUDIO_FIFO_CAPACITY_FRAMES * SAT_AUDIO_FIFO_CHANNEL_COUNT
    ];
};

struct SATFIFOReader {
    SATFIFOReaderConfiguration configuration;

    // Used only by the playback callback.
    bool playing;
    uint32_t fadeInPosition;
    uint32_t targetFrames;
    uint64_t levelSum;
    uint64_t levelFrames;
    uint64_t framesSinceDropout;
    float continuation[SAT_FIFO_READER_MAXIMUM_CROSSFADE_FRAMES];
    float candidates[SAT_FIFO_READER_MAXIMUM_SPLICE_SEARCH_FRAMES + SAT_FIFO_READER_MAXIMUM_CROSSFADE_FRAMES + 1];

    // Written by the playback callback, read from any thread.
    _Atomic(uint64_t) framesPlayed;
    _Atomic(uint64_t) silentFrames;
    _Atomic(uint64_t) dropouts;
    _Atomic(uint64_t) splices;
    _Atomic(uint64_t) framesSkipped;
    _Atomic(uint64_t) framesRepeated;
    _Atomic(uint32_t) latencyTargetFrames;
};

static uint32_t FloatToBits(float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float BitsToFloat(uint32_t bits) {
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

SATAudioFIFO* SATAudioFIFOCreate(void) {
    SATAudioFIFO* fifo = calloc(1, sizeof(SATAudioFIFO));
    if (fifo != NULL) SATAudioFIFOClear(fifo);
    return fifo;
}

void SATAudioFIFODestroy(SATAudioFIFO* fifo) {
    free(fifo);
}

void SATAudioFIFOClear(SATAudioFIFO* fifo) {
    if (fifo == NULL) return;
    atomic_store_explicit(&fifo->readFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&fifo->writeFrame, 0, memory_order_relaxed);
    atomic_store_explicit(&fifo->totalFramesWritten, 0, memory_order_relaxed);
    atomic_store_explicit(&fifo->totalFramesRead, 0, memory_order_relaxed);
    atomic_store_explicit(&fifo->droppedFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&fifo->underflowFrames, 0, memory_order_relaxed);
}

uint32_t SATAudioFIFOWrite(
    SATAudioFIFO* fifo,
    const float* interleavedSamples,
    uint32_t frameCount
) {
    if (fifo == NULL || interleavedSamples == NULL || frameCount == 0) return 0;

    const uint64_t writeFrame = atomic_load_explicit(&fifo->writeFrame, memory_order_relaxed);
    const uint64_t readFrame = atomic_load_explicit(&fifo->readFrame, memory_order_acquire);
    const uint64_t used = writeFrame - readFrame;
    const uint32_t freeFrames = used >= SAT_AUDIO_FIFO_CAPACITY_FRAMES
        ? 0
        : (uint32_t)(SAT_AUDIO_FIFO_CAPACITY_FRAMES - used);
    const uint32_t framesToWrite = frameCount < freeFrames ? frameCount : freeFrames;

    for (uint32_t offset = 0; offset < framesToWrite; ++offset) {
        const uint64_t absoluteFrame = writeFrame + offset;
        const uint32_t ringFrame = (uint32_t)(absoluteFrame % SAT_AUDIO_FIFO_CAPACITY_FRAMES);
        const uint32_t ringSample = ringFrame * SAT_AUDIO_FIFO_CHANNEL_COUNT;
        const uint32_t sourceSample = offset * SAT_AUDIO_FIFO_CHANNEL_COUNT;
        atomic_store_explicit(
            &fifo->sampleBits[ringSample],
            FloatToBits(interleavedSamples[sourceSample]),
            memory_order_relaxed
        );
        atomic_store_explicit(
            &fifo->sampleBits[ringSample + 1],
            FloatToBits(interleavedSamples[sourceSample + 1]),
            memory_order_relaxed
        );
    }

    atomic_store_explicit(&fifo->writeFrame, writeFrame + framesToWrite, memory_order_release);
    atomic_fetch_add_explicit(&fifo->totalFramesWritten, framesToWrite, memory_order_relaxed);
    atomic_fetch_add_explicit(
        &fifo->droppedFrames,
        frameCount - framesToWrite,
        memory_order_relaxed
    );
    return framesToWrite;
}

uint32_t SATAudioFIFORead(
    SATAudioFIFO* fifo,
    float* interleavedSamples,
    uint32_t frameCount
) {
    if (fifo == NULL || interleavedSamples == NULL || frameCount == 0) return 0;

    const uint64_t readFrame = atomic_load_explicit(&fifo->readFrame, memory_order_relaxed);
    const uint64_t writeFrame = atomic_load_explicit(&fifo->writeFrame, memory_order_acquire);
    const uint64_t available = writeFrame - readFrame;
    const uint32_t framesToRead = available < frameCount ? (uint32_t)available : frameCount;

    for (uint32_t offset = 0; offset < framesToRead; ++offset) {
        const uint64_t absoluteFrame = readFrame + offset;
        const uint32_t ringFrame = (uint32_t)(absoluteFrame % SAT_AUDIO_FIFO_CAPACITY_FRAMES);
        const uint32_t ringSample = ringFrame * SAT_AUDIO_FIFO_CHANNEL_COUNT;
        const uint32_t destinationSample = offset * SAT_AUDIO_FIFO_CHANNEL_COUNT;
        interleavedSamples[destinationSample] = BitsToFloat(
            atomic_load_explicit(&fifo->sampleBits[ringSample], memory_order_relaxed)
        );
        interleavedSamples[destinationSample + 1] = BitsToFloat(
            atomic_load_explicit(&fifo->sampleBits[ringSample + 1], memory_order_relaxed)
        );
    }

    const uint32_t missingFrames = frameCount - framesToRead;
    if (missingFrames > 0) {
        memset(
            interleavedSamples + framesToRead * SAT_AUDIO_FIFO_CHANNEL_COUNT,
            0,
            (size_t)missingFrames * SAT_AUDIO_FIFO_CHANNEL_COUNT * sizeof(float)
        );
    }

    atomic_store_explicit(&fifo->readFrame, readFrame + framesToRead, memory_order_release);
    atomic_fetch_add_explicit(&fifo->totalFramesRead, framesToRead, memory_order_relaxed);
    atomic_fetch_add_explicit(&fifo->underflowFrames, missingFrames, memory_order_relaxed);
    return framesToRead;
}

void SATAudioFIFOGetStats(
    const SATAudioFIFO* fifo,
    uint64_t* framesWritten,
    uint64_t* framesRead,
    uint64_t* droppedFrames,
    uint64_t* underflowFrames
) {
    if (fifo == NULL) return;
    if (framesWritten != NULL) {
        *framesWritten = atomic_load_explicit(&fifo->totalFramesWritten, memory_order_relaxed);
    }
    if (framesRead != NULL) {
        *framesRead = atomic_load_explicit(&fifo->totalFramesRead, memory_order_relaxed);
    }
    if (droppedFrames != NULL) {
        *droppedFrames = atomic_load_explicit(&fifo->droppedFrames, memory_order_relaxed);
    }
    if (underflowFrames != NULL) {
        *underflowFrames = atomic_load_explicit(&fifo->underflowFrames, memory_order_relaxed);
    }
}

uint32_t SATAudioFIFOAvailableFrames(const SATAudioFIFO* fifo) {
    if (fifo == NULL) return 0;
    const uint64_t readFrame = atomic_load_explicit(&fifo->readFrame, memory_order_acquire);
    const uint64_t writeFrame = atomic_load_explicit(&fifo->writeFrame, memory_order_acquire);
    const uint64_t available = writeFrame - readFrame;
    return available > UINT32_MAX ? UINT32_MAX : (uint32_t)available;
}

static uint64_t Min64(uint64_t a, uint64_t b) { return a < b ? a : b; }
static uint64_t Max64(uint64_t a, uint64_t b) { return a > b ? a : b; }

static float FIFOSample(const SATAudioFIFO* fifo, uint64_t frame, uint32_t channel) {
    const uint32_t ringFrame = (uint32_t)(frame % SAT_AUDIO_FIFO_CAPACITY_FRAMES);
    return BitsToFloat(atomic_load_explicit(
        &fifo->sampleBits[ringFrame * SAT_AUDIO_FIFO_CHANNEL_COUNT + channel],
        memory_order_relaxed
    ));
}

static float FIFOMono(const SATAudioFIFO* fifo, uint64_t frame) {
    return 0.5f * (FIFOSample(fifo, frame, 0) + FIFOSample(fifo, frame, 1));
}

static void CopyFrames(const SATAudioFIFO* fifo, uint64_t firstFrame, float* output, uint32_t frameCount) {
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        for (uint32_t channel = 0; channel < SAT_AUDIO_FIFO_CHANNEL_COUNT; ++channel) {
            output[frame * SAT_AUDIO_FIFO_CHANNEL_COUNT + channel] = FIFOSample(fifo, firstFrame + frame, channel);
        }
    }
}

/// The reader owns the read position. A repeat splice moves it backwards, so the
/// running total counts net frames consumed.
static void MoveReadFrame(SATAudioFIFO* fifo, uint64_t from, uint64_t to) {
    atomic_store_explicit(&fifo->readFrame, to, memory_order_release);
    atomic_fetch_add_explicit(&fifo->totalFramesRead, to - from, memory_order_relaxed);
}

/// Rises from near 0 at position 0 to exactly 1 at position length - 1.
static double RaisedCosine(uint32_t position, uint32_t length) {
    return 0.5 * (1.0 - cos(M_PI * (double)(position + 1) / (double)length));
}

static void ScaleFrame(float* output, uint32_t frame, float gain) {
    for (uint32_t channel = 0; channel < SAT_AUDIO_FIFO_CHANNEL_COUNT; ++channel) {
        output[frame * SAT_AUDIO_FIFO_CHANNEL_COUNT + channel] *= gain;
    }
}

static void ApplyFadeIn(SATFIFOReader* reader, float* output, uint32_t frameCount) {
    const uint32_t fadeFrames = reader->configuration.fadeFrames;
    for (uint32_t frame = 0; frame < frameCount && reader->fadeInPosition < fadeFrames; ++frame) {
        ScaleFrame(output, frame, (float)RaisedCosine(reader->fadeInPosition++, fadeFrames));
    }
}

/// How well a candidate matches the continuation, comparing every `stride`th frame.
static double MatchScore(
    const SATFIFOReader* reader,
    const float* candidate,
    uint32_t crossfade,
    uint32_t stride
) {
    double correlation = 0;
    double energy = 1e-12;
    for (uint32_t frame = 0; frame < crossfade; frame += stride) {
        const double sample = candidate[frame];
        correlation += reader->continuation[frame] * sample;
        energy += sample * sample;
    }
    return correlation / sqrt(energy);
}

/// Among offsets from `lowest` to `highest`, finds where the buffered audio best
/// matches the audio that would otherwise play next, so a crossfade between them
/// keeps sustained bass in phase instead of cancelling it.
static int64_t AlignSplice(
    SATFIFOReader* reader,
    const SATAudioFIFO* fifo,
    uint64_t readFrame,
    int64_t lowest,
    int64_t highest,
    uint32_t crossfade
) {
    for (uint32_t frame = 0; frame < crossfade; ++frame) {
        reader->continuation[frame] = FIFOMono(fifo, readFrame + frame);
    }
    const uint64_t firstCandidate = readFrame + (uint64_t)lowest;
    const uint32_t span = (uint32_t)(highest - lowest) + crossfade;
    for (uint32_t frame = 0; frame < span; ++frame) {
        reader->candidates[frame] = FIFOMono(fifo, firstCandidate + frame);
    }

    // Bass decides the match, so a coarse pass over sparse frames finds the right
    // cycle and a fine pass around it finds the frame. Strides follow the search
    // range, which follows the sample rate, so the cost stays the same at any rate
    // and stays small even in an unoptimized build.
    const uint32_t search = reader->configuration.spliceSearchFrames;
    const uint32_t stride = search / 120 > 1 ? search / 120 : 1;
    const int64_t coarseStep = stride / 2 > 1 ? stride / 2 : 1;
    const uint32_t fineStride = stride / 4 > 1 ? stride / 4 : 1;

    int64_t best = lowest;
    double bestScore = -INFINITY;
    for (int64_t offset = lowest; offset <= highest; offset += coarseStep) {
        const double score = MatchScore(reader, reader->candidates + (offset - lowest), crossfade, stride);
        if (score > bestScore) {
            bestScore = score;
            best = offset;
        }
    }

    const int64_t from = best - coarseStep > lowest ? best - coarseStep : lowest;
    const int64_t to = best + coarseStep < highest ? best + coarseStep : highest;
    bestScore = -INFINITY;
    for (int64_t offset = from; offset <= to; ++offset) {
        const double score = MatchScore(reader, reader->candidates + (offset - lowest), crossfade, fineStride);
        if (score > bestScore) {
            bestScore = score;
            best = offset;
        }
    }
    return best;
}

/// Returns how far to move the read position, or 0 when the average level is
/// close enough to the target or no safe splice exists right now.
static int64_t ChooseSplice(
    SATFIFOReader* reader,
    const SATAudioFIFO* fifo,
    uint64_t readFrame,
    uint64_t level,
    uint64_t averageLevel,
    uint64_t target,
    uint64_t tolerance,
    uint32_t frameCount
) {
    const SATFIFOReaderConfiguration* configuration = &reader->configuration;
    const int64_t halfSearch = configuration->spliceSearchFrames / 2;
    const uint32_t crossfade = frameCount < configuration->crossfadeFrames
        ? frameCount
        : configuration->crossfadeFrames;
    if (crossfade == 0) return 0;

    int64_t lowest;
    int64_t highest;
    if (averageLevel > target + tolerance) {
        // Capture delivered more than playback used: skip ahead, keeping this
        // callback's audio and a fade's worth behind the new position.
        const int64_t ideal = (int64_t)(averageLevel - target);
        lowest = ideal - halfSearch;
        highest = ideal + halfSearch;
        const int64_t furthest = (int64_t)level - (int64_t)frameCount - (int64_t)configuration->fadeFrames;
        if (highest > furthest) highest = furthest;
        if (lowest < 1) lowest = 1;
    } else if (averageLevel + tolerance < target) {
        // Capture fell behind: repeat audio that already played, as long as
        // the writer can't reach it.
        const int64_t ideal = (int64_t)(target - averageLevel);
        lowest = -(ideal + halfSearch);
        highest = -(ideal - halfSearch);
        const uint64_t clearance = level + SAT_FIFO_READER_WRITER_CLEARANCE_FRAMES;
        const uint64_t furthestBack = Min64(
            readFrame,
            clearance >= SAT_AUDIO_FIFO_CAPACITY_FRAMES ? 0 : SAT_AUDIO_FIFO_CAPACITY_FRAMES - clearance
        );
        if (lowest < -(int64_t)furthestBack) lowest = -(int64_t)furthestBack;
        if (highest > -1) highest = -1;
    } else {
        return 0;
    }
    if (lowest > highest) return 0;
    return AlignSplice(reader, fifo, readFrame, lowest, highest, crossfade);
}

static void Splice(
    SATFIFOReader* reader,
    SATAudioFIFO* fifo,
    uint64_t readFrame,
    int64_t offset,
    float* output,
    uint32_t frameCount
) {
    const uint32_t crossfade = frameCount < reader->configuration.crossfadeFrames
        ? frameCount
        : reader->configuration.crossfadeFrames;
    const uint64_t splicedFrame = readFrame + (uint64_t)offset;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        // Equal-gain weights never raise the level above either source.
        const float weight = frame < crossfade ? (float)RaisedCosine(frame, crossfade + 1) : 1;
        for (uint32_t channel = 0; channel < SAT_AUDIO_FIFO_CHANNEL_COUNT; ++channel) {
            const float next = FIFOSample(fifo, splicedFrame + frame, channel);
            const float previous = weight < 1 ? FIFOSample(fifo, readFrame + frame, channel) : 0;
            output[frame * SAT_AUDIO_FIFO_CHANNEL_COUNT + channel] = (1 - weight) * previous + weight * next;
        }
    }
    MoveReadFrame(fifo, readFrame, splicedFrame + frameCount);
    atomic_fetch_add_explicit(&reader->splices, 1, memory_order_relaxed);
    if (offset > 0) {
        atomic_fetch_add_explicit(&reader->framesSkipped, (uint64_t)offset, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&reader->framesRepeated, (uint64_t)(-offset), memory_order_relaxed);
    }
}

SATFIFOReader* SATFIFOReaderCreate(void) {
    return calloc(1, sizeof(SATFIFOReader));
}

void SATFIFOReaderDestroy(SATFIFOReader* reader) {
    free(reader);
}

void SATFIFOReaderReset(SATFIFOReader* reader, const SATFIFOReaderConfiguration* configuration) {
    if (reader == NULL) return;
    if (configuration != NULL) {
        SATFIFOReaderConfiguration clamped = *configuration;
        if (clamped.maximumLatencyFrames < clamped.minimumLatencyFrames) {
            clamped.maximumLatencyFrames = clamped.minimumLatencyFrames;
        }
        if (clamped.fadeFrames == 0) clamped.fadeFrames = 1;
        if (clamped.crossfadeFrames > SAT_FIFO_READER_MAXIMUM_CROSSFADE_FRAMES) {
            clamped.crossfadeFrames = SAT_FIFO_READER_MAXIMUM_CROSSFADE_FRAMES;
        }
        if (clamped.spliceSearchFrames > SAT_FIFO_READER_MAXIMUM_SPLICE_SEARCH_FRAMES) {
            clamped.spliceSearchFrames = SAT_FIFO_READER_MAXIMUM_SPLICE_SEARCH_FRAMES;
        }
        if (clamped.checkFrames == 0) clamped.checkFrames = 1;
        reader->configuration = clamped;
    }

    const SATFIFOReaderConfiguration* settings = &reader->configuration;
    uint32_t target = settings->initialLatencyFrames;
    if (target < settings->minimumLatencyFrames) target = settings->minimumLatencyFrames;
    if (target > settings->maximumLatencyFrames) target = settings->maximumLatencyFrames;

    reader->playing = false;
    reader->fadeInPosition = 0;
    reader->targetFrames = target;
    reader->levelSum = 0;
    reader->levelFrames = 0;
    reader->framesSinceDropout = 0;
    atomic_store_explicit(&reader->framesPlayed, 0, memory_order_relaxed);
    atomic_store_explicit(&reader->silentFrames, 0, memory_order_relaxed);
    atomic_store_explicit(&reader->dropouts, 0, memory_order_relaxed);
    atomic_store_explicit(&reader->splices, 0, memory_order_relaxed);
    atomic_store_explicit(&reader->framesSkipped, 0, memory_order_relaxed);
    atomic_store_explicit(&reader->framesRepeated, 0, memory_order_relaxed);
    atomic_store_explicit(&reader->latencyTargetFrames, target, memory_order_relaxed);
}

void SATFIFOReaderRead(
    SATFIFOReader* reader,
    SATAudioFIFO* fifo,
    float* interleavedSamples,
    uint32_t frameCount
) {
    if (reader == NULL || fifo == NULL || interleavedSamples == NULL || frameCount == 0) return;
    const SATFIFOReaderConfiguration* configuration = &reader->configuration;

    const uint64_t readFrame = atomic_load_explicit(&fifo->readFrame, memory_order_relaxed);
    const uint64_t writeFrame = atomic_load_explicit(&fifo->writeFrame, memory_order_acquire);
    const uint64_t level = writeFrame - readFrame;
    // After a normal read at least a fade's worth stays buffered, so running dry
    // can always fade out instead of stopping mid-wave.
    const uint64_t reserve = (uint64_t)frameCount + configuration->fadeFrames;
    const uint64_t tolerance = Max64(configuration->spliceSearchFrames, frameCount);
    const uint64_t target = Max64(reader->targetFrames, reserve + frameCount + tolerance);
    atomic_store_explicit(
        &reader->latencyTargetFrames,
        (uint32_t)Min64(target, UINT32_MAX),
        memory_order_relaxed
    );

    if (!reader->playing) {
        if (level < target) {
            memset(interleavedSamples, 0, (size_t)frameCount * SAT_AUDIO_FIFO_CHANNEL_COUNT * sizeof(float));
            atomic_fetch_add_explicit(&reader->silentFrames, frameCount, memory_order_relaxed);
            return;
        }
        reader->playing = true;
        reader->fadeInPosition = 0;
        reader->levelSum = 0;
        reader->levelFrames = 0;
    }

    if (level < reserve) {
        const uint32_t count = (uint32_t)Min64(level, frameCount);
        CopyFrames(fifo, readFrame, interleavedSamples, count);
        ApplyFadeIn(reader, interleavedSamples, count);
        const uint32_t fadeLength = count < configuration->fadeFrames ? count : configuration->fadeFrames;
        for (uint32_t position = 0; position < fadeLength; ++position) {
            ScaleFrame(
                interleavedSamples,
                count - fadeLength + position,
                (float)(1.0 - RaisedCosine(position, fadeLength))
            );
        }
        memset(
            interleavedSamples + (size_t)count * SAT_AUDIO_FIFO_CHANNEL_COUNT,
            0,
            (size_t)(frameCount - count) * SAT_AUDIO_FIFO_CHANNEL_COUNT * sizeof(float)
        );
        MoveReadFrame(fifo, readFrame, readFrame + count);
        atomic_fetch_add_explicit(&reader->framesPlayed, count, memory_order_relaxed);
        atomic_fetch_add_explicit(&reader->silentFrames, frameCount - count, memory_order_relaxed);
        atomic_fetch_add_explicit(&reader->dropouts, 1, memory_order_relaxed);

        // Buffer more before playing again, within the configured bounds.
        reader->playing = false;
        reader->framesSinceDropout = 0;
        reader->targetFrames = (uint32_t)Min64(
            Min64(target * 2, Max64(configuration->maximumLatencyFrames, target)),
            UINT32_MAX
        );
        return;
    }

    reader->levelSum += level * frameCount;
    reader->levelFrames += frameCount;
    int64_t offset = 0;
    if (reader->fadeInPosition >= configuration->fadeFrames
        && reader->levelFrames >= configuration->checkFrames) {
        const uint64_t averageLevel = reader->levelSum / reader->levelFrames;
        reader->levelSum = 0;
        reader->levelFrames = 0;
        offset = ChooseSplice(reader, fifo, readFrame, level, averageLevel, target, tolerance, frameCount);
    }

    if (offset != 0) {
        Splice(reader, fifo, readFrame, offset, interleavedSamples, frameCount);
    } else {
        CopyFrames(fifo, readFrame, interleavedSamples, frameCount);
        ApplyFadeIn(reader, interleavedSamples, frameCount);
        MoveReadFrame(fifo, readFrame, readFrame + frameCount);
    }
    atomic_fetch_add_explicit(&reader->framesPlayed, frameCount, memory_order_relaxed);

    reader->framesSinceDropout += frameCount;
    if (reader->framesSinceDropout >= configuration->relaxFrames) {
        reader->framesSinceDropout = 0;
        const uint32_t lowered = reader->targetFrames - reader->targetFrames / 4;
        reader->targetFrames = lowered > configuration->minimumLatencyFrames
            ? lowered
            : configuration->minimumLatencyFrames;
    }
}

void SATFIFOReaderGetStats(const SATFIFOReader* reader, SATFIFOReaderStats* stats) {
    if (reader == NULL || stats == NULL) return;
    stats->framesPlayed = atomic_load_explicit(&reader->framesPlayed, memory_order_relaxed);
    stats->silentFrames = atomic_load_explicit(&reader->silentFrames, memory_order_relaxed);
    stats->dropouts = atomic_load_explicit(&reader->dropouts, memory_order_relaxed);
    stats->splices = atomic_load_explicit(&reader->splices, memory_order_relaxed);
    stats->framesSkipped = atomic_load_explicit(&reader->framesSkipped, memory_order_relaxed);
    stats->framesRepeated = atomic_load_explicit(&reader->framesRepeated, memory_order_relaxed);
    stats->latencyTargetFrames = atomic_load_explicit(&reader->latencyTargetFrames, memory_order_relaxed);
}
