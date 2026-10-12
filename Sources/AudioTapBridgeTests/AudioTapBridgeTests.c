#include "AudioTapBridgeTests.h"

#include "AudioTapBridge.h"

#include <math.h>
#include <stddef.h>

typedef void (*FailureReporter)(const char* file, int line, const char* expression);

#define CHECK(condition) \
    do { if (!(condition)) report(__FILE__, __LINE__, #condition); } while (0)

enum { TestBlock = 256, ToneAmplitudeTimes10 = 5, TonePeriod = 480 };

/// At 48 kHz: a 2048-frame target, 64-frame fades, a 256-frame crossfade, and a
/// splice search of one 100 Hz period. The target never relaxes unless a test
/// asks for it.
static SATFIFOReaderConfiguration TestConfiguration(void) {
    SATFIFOReaderConfiguration configuration = {
        .initialLatencyFrames = 2048,
        .minimumLatencyFrames = 1024,
        .maximumLatencyFrames = 8192,
        .fadeFrames = 64,
        .crossfadeFrames = 256,
        .spliceSearchFrames = TonePeriod,
        .checkFrames = 4800,
        .relaxFrames = UINT64_MAX,
    };
    return configuration;
}

static void WriteConstant(SATAudioFIFO* fifo, float value, uint32_t frameCount) {
    float buffer[2 * 512];
    while (frameCount > 0) {
        const uint32_t chunk = frameCount < 512 ? frameCount : 512;
        for (uint32_t sample = 0; sample < 2 * chunk; ++sample) buffer[sample] = value;
        SATAudioFIFOWrite(fifo, buffer, chunk);
        frameCount -= chunk;
    }
}

/// A continuous 100 Hz sine at 0.5, as capture would deliver it.
typedef struct { uint64_t frame; } Tone;

static void WriteTone(SATAudioFIFO* fifo, Tone* tone, uint32_t frameCount) {
    float buffer[2 * 512];
    while (frameCount > 0) {
        const uint32_t chunk = frameCount < 512 ? frameCount : 512;
        for (uint32_t frame = 0; frame < chunk; ++frame) {
            const float value = (float)(ToneAmplitudeTimes10 / 10.0
                * sin(2 * M_PI * (double)(tone->frame++) / TonePeriod));
            buffer[2 * frame] = value;
            buffer[2 * frame + 1] = value;
        }
        SATAudioFIFOWrite(fifo, buffer, chunk);
        frameCount -= chunk;
    }
}

/// A steady voiced-speech surrogate: a pitch plus inharmonic formants. Unlike a
/// bass tone, it exposes a crossfade that lines up one frequency by sacrificing
/// the rest and audibly pumps the overall level.
typedef struct { uint64_t frame; } Speech;

static void WriteSpeech(SATAudioFIFO* fifo, Speech* speech, uint32_t frameCount) {
    float buffer[2 * 512];
    while (frameCount > 0) {
        const uint32_t chunk = frameCount < 512 ? frameCount : 512;
        for (uint32_t frame = 0; frame < chunk; ++frame) {
            const double time = (double)(speech->frame++) / 48000.0;
            const float value = (float)(
                0.20 * sin(2 * M_PI * 137 * time)
                + 0.12 * sin(2 * M_PI * 730 * time)
                + 0.08 * sin(2 * M_PI * 1090 * time)
            );
            buffer[2 * frame] = value;
            buffer[2 * frame + 1] = value;
        }
        SATAudioFIFOWrite(fifo, buffer, chunk);
        frameCount -= chunk;
    }
}

/// Follows the left channel across reads: its largest sample-to-sample jump, its
/// loudest sample, and the quietest peak of any tone period after `ignoredFrames`.
typedef struct {
    uint64_t ignoredFrames;
    uint64_t frames;
    float previous;
    float largestJump;
    float loudest;
    float periodPeak;
    uint32_t periodFrames;
    float quietestPeriodPeak;
} Listener;

static Listener MakeListener(uint64_t ignoredFrames) {
    Listener listener = { .ignoredFrames = ignoredFrames, .quietestPeriodPeak = 1 };
    return listener;
}

static void Listen(Listener* listener, const float* output, uint32_t frameCount) {
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        const float sample = output[2 * frame];
        const float jump = fabsf(sample - listener->previous);
        if (jump > listener->largestJump) listener->largestJump = jump;
        if (fabsf(sample) > listener->loudest) listener->loudest = fabsf(sample);
        listener->previous = sample;
        if (listener->frames++ < listener->ignoredFrames) continue;
        if (fabsf(sample) > listener->periodPeak) listener->periodPeak = fabsf(sample);
        if (++listener->periodFrames == TonePeriod) {
            if (listener->periodPeak < listener->quietestPeriodPeak) {
                listener->quietestPeriodPeak = listener->periodPeak;
            }
            listener->periodPeak = 0;
            listener->periodFrames = 0;
        }
    }
}

static SATFIFOReaderStats Stats(const SATFIFOReader* reader) {
    SATFIFOReaderStats stats = { 0 };
    SATFIFOReaderGetStats(reader, &stats);
    return stats;
}

static void TestFIFORoundTripAndUnderflow(FailureReporter report) {
    SATAudioFIFO* fifo = SATAudioFIFOCreate();
    CHECK(fifo != NULL);
    if (fifo == NULL) return;

    float source[] = { 0.25f, -0.25f, 0.5f, -0.5f };
    CHECK(SATAudioFIFOWrite(fifo, source, 2) == 2);
    CHECK(SATAudioFIFOAvailableFrames(fifo) == 2);

    float output[6] = { 9, 9, 9, 9, 9, 9 };
    CHECK(SATAudioFIFORead(fifo, output, 3) == 2);
    CHECK(output[0] == 0.25f && output[1] == -0.25f);
    CHECK(output[2] == 0.5f && output[3] == -0.5f);
    CHECK(output[4] == 0 && output[5] == 0);
    uint64_t written = 0, read = 0, dropped = 0, underflow = 0;
    SATAudioFIFOGetStats(fifo, &written, &read, &dropped, &underflow);
    CHECK(written == 2 && read == 2 && dropped == 0 && underflow == 1);

    SATAudioFIFODestroy(fifo);
}

static void TestReaderBuffersToTheLatencyTargetThenFadesIn(FailureReporter report) {
    SATAudioFIFO* fifo = SATAudioFIFOCreate();
    SATFIFOReader* reader = SATFIFOReaderCreate();
    CHECK(fifo != NULL && reader != NULL);
    if (fifo == NULL || reader == NULL) return;
    const SATFIFOReaderConfiguration configuration = TestConfiguration();
    SATFIFOReaderReset(reader, &configuration);
    float output[2 * TestBlock];

    WriteConstant(fifo, 0.5f, 2000);
    SATFIFOReaderRead(reader, fifo, output, TestBlock);
    CHECK(output[0] == 0 && output[2 * TestBlock - 2] == 0);
    CHECK(SATAudioFIFOAvailableFrames(fifo) == 2000);

    WriteConstant(fifo, 0.5f, 48);
    SATFIFOReaderRead(reader, fifo, output, TestBlock);
    CHECK(output[0] > 0 && output[0] < 0.01f);
    CHECK(fabsf(output[2 * TestBlock - 2] - 0.5f) < 1e-6f);

    const SATFIFOReaderStats stats = Stats(reader);
    CHECK(stats.silentFrames == TestBlock && stats.framesPlayed == TestBlock);
    CHECK(stats.dropouts == 0 && stats.latencyTargetFrames == 2048);

    SATFIFOReaderDestroy(reader);
    SATAudioFIFODestroy(fifo);
}

static void TestReaderFadesOutWhenCaptureRunsDry(FailureReporter report) {
    SATAudioFIFO* fifo = SATAudioFIFOCreate();
    SATFIFOReader* reader = SATFIFOReaderCreate();
    CHECK(fifo != NULL && reader != NULL);
    if (fifo == NULL || reader == NULL) return;
    const SATFIFOReaderConfiguration configuration = TestConfiguration();
    SATFIFOReaderReset(reader, &configuration);
    float output[2 * TestBlock];
    Listener listener = MakeListener(0);

    // Eight blocks of audio, then nothing: the eighth block has to end in silence.
    WriteConstant(fifo, 0.5f, 2048);
    for (int block = 0; block < 9; ++block) {
        SATFIFOReaderRead(reader, fifo, output, TestBlock);
        Listen(&listener, output, TestBlock);
        if (block == 7) CHECK(output[2 * TestBlock - 2] == 0);
    }
    CHECK(listener.largestJump < 0.02f);

    const SATFIFOReaderStats stats = Stats(reader);
    CHECK(stats.framesPlayed == 8 * TestBlock && stats.silentFrames == TestBlock);
    CHECK(stats.dropouts == 1 && stats.latencyTargetFrames == 4096);

    SATFIFOReaderDestroy(reader);
    SATAudioFIFODestroy(fifo);
}

static void TestReaderSkipsExcessLatencyWithAnAlignedSplice(FailureReporter report) {
    SATAudioFIFO* fifo = SATAudioFIFOCreate();
    SATFIFOReader* reader = SATFIFOReaderCreate();
    CHECK(fifo != NULL && reader != NULL);
    if (fifo == NULL || reader == NULL) return;
    const SATFIFOReaderConfiguration configuration = TestConfiguration();
    SATFIFOReaderReset(reader, &configuration);
    float output[2 * TestBlock];
    Listener listener = MakeListener(TonePeriod);
    Tone tone = { 0 };

    WriteTone(fifo, &tone, 2048);
    for (int block = 0; block < 200; ++block) {
        // A capture burst leaves 1536 frames of latency nobody needs.
        if (block == 40) WriteTone(fifo, &tone, 1536);
        WriteTone(fifo, &tone, TestBlock);
        SATFIFOReaderRead(reader, fifo, output, TestBlock);
        Listen(&listener, output, TestBlock);
    }

    const SATFIFOReaderStats stats = Stats(reader);
    CHECK(stats.dropouts == 0 && stats.splices == 1 && stats.framesRepeated == 0);
    CHECK(stats.framesSkipped >= 1390 && stats.framesSkipped <= 1870);
    CHECK(SATAudioFIFOAvailableFrames(fifo) >= 1700 && SATAudioFIFOAvailableFrames(fifo) <= 2200);
    // In phase, the splice neither jumps nor dips the tone.
    CHECK(listener.largestJump < 0.01f);
    CHECK(listener.quietestPeriodPeak > 0.45f);
    CHECK(listener.loudest <= 0.5001f);

    SATFIFOReaderDestroy(reader);
    SATAudioFIFODestroy(fifo);
}

static void TestReaderRepeatsAudioWhenCaptureFallsBehind(FailureReporter report) {
    SATAudioFIFO* fifo = SATAudioFIFOCreate();
    SATFIFOReader* reader = SATFIFOReaderCreate();
    CHECK(fifo != NULL && reader != NULL);
    if (fifo == NULL || reader == NULL) return;
    const SATFIFOReaderConfiguration configuration = TestConfiguration();
    SATFIFOReaderReset(reader, &configuration);
    float output[2 * TestBlock];
    Listener listener = MakeListener(TonePeriod);
    Tone tone = { 0 };

    // Capture delivers 8 frames fewer than playback uses in every block.
    WriteTone(fifo, &tone, 2048);
    for (int block = 0; block < 400; ++block) {
        WriteTone(fifo, &tone, block == 0 ? TestBlock : TestBlock - 8);
        SATFIFOReaderRead(reader, fifo, output, TestBlock);
        Listen(&listener, output, TestBlock);
    }

    const SATFIFOReaderStats stats = Stats(reader);
    CHECK(stats.dropouts == 0 && stats.splices >= 3);
    CHECK(stats.framesRepeated > 0 && stats.framesSkipped == 0);
    CHECK(listener.largestJump < 0.01f);
    CHECK(listener.quietestPeriodPeak > 0.45f);
    CHECK(listener.loudest <= 0.5001f);

    SATFIFOReaderDestroy(reader);
    SATAudioFIFODestroy(fifo);
}

static void TestReaderSpeechSpliceDoesNotPumpTheLevel(FailureReporter report) {
    SATAudioFIFO* fifo = SATAudioFIFOCreate();
    SATFIFOReader* reader = SATFIFOReaderCreate();
    CHECK(fifo != NULL && reader != NULL);
    if (fifo == NULL || reader == NULL) return;
    const SATFIFOReaderConfiguration configuration = TestConfiguration();
    SATFIFOReaderReset(reader, &configuration);
    float output[2 * TestBlock];
    Speech speech = { 0 };
    double quietestRMS = INFINITY;
    double loudestRMS = 0;

    WriteSpeech(fifo, &speech, 2048);
    for (int block = 0; block < 200; ++block) {
        // Force the same excess-latency skip as the tone test, but while the
        // buffer carries speech-like broadband content.
        if (block == 40) WriteSpeech(fifo, &speech, 1536);
        WriteSpeech(fifo, &speech, TestBlock);
        SATFIFOReaderRead(reader, fifo, output, TestBlock);
        if (block < 2) continue; // Ignore the route's intentional start fade.

        double energy = 0;
        for (uint32_t frame = 0; frame < TestBlock; ++frame) {
            const double sample = output[2 * frame];
            energy += sample * sample;
        }
        const double rms = sqrt(energy / TestBlock);
        if (rms < quietestRMS) quietestRMS = rms;
        if (rms > loudestRMS) loudestRMS = rms;
    }

    const SATFIFOReaderStats stats = Stats(reader);
    CHECK(stats.dropouts == 0 && stats.splices == 1);
    // Normal blocks sit near 0.174 RMS. A splice may move syllable detail, but
    // must not create a conspicuous fade or boost.
    CHECK(quietestRMS > 0.10);
    CHECK(loudestRMS < 0.25);

    SATFIFOReaderDestroy(reader);
    SATAudioFIFODestroy(fifo);
}

static void TestReaderLowersTheTargetAfterCleanPlayback(FailureReporter report) {
    SATAudioFIFO* fifo = SATAudioFIFOCreate();
    SATFIFOReader* reader = SATFIFOReaderCreate();
    CHECK(fifo != NULL && reader != NULL);
    if (fifo == NULL || reader == NULL) return;
    SATFIFOReaderConfiguration configuration = TestConfiguration();
    configuration.relaxFrames = 48000;
    SATFIFOReaderReset(reader, &configuration);
    float output[2 * TestBlock];
    Tone tone = { 0 };

    WriteConstant(fifo, 0.5f, 2048);
    for (int block = 0; block < 9; ++block) SATFIFOReaderRead(reader, fifo, output, TestBlock);
    CHECK(Stats(reader).latencyTargetFrames == 4096);

    // A little over the 48000-frame relax period of steady playback.
    for (int block = 0; block < 230; ++block) {
        WriteTone(fifo, &tone, TestBlock);
        SATFIFOReaderRead(reader, fifo, output, TestBlock);
    }
    const SATFIFOReaderStats stats = Stats(reader);
    CHECK(stats.dropouts == 1 && stats.latencyTargetFrames == 3072);

    SATFIFOReaderDestroy(reader);
    SATAudioFIFODestroy(fifo);
}

void SATAudioTapBridgeRunTests(FailureReporter reportFailure) {
    TestFIFORoundTripAndUnderflow(reportFailure);
    TestReaderBuffersToTheLatencyTargetThenFadesIn(reportFailure);
    TestReaderFadesOutWhenCaptureRunsDry(reportFailure);
    TestReaderSkipsExcessLatencyWithAnAlignedSplice(reportFailure);
    TestReaderRepeatsAudioWhenCaptureFallsBehind(reportFailure);
    TestReaderSpeechSpliceDoesNotPumpTheLevel(reportFailure);
    TestReaderLowersTheTargetAfterCleanPlayback(reportFailure);
}
