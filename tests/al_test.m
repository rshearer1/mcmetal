/* Checks libmcmetal-al.dylib (audio/mcm_al.m) the way Minecraft, Voice Chat and Sound Physics use it, then reads
 * back what the engine played (MCMETAL_AL_TAP) and checks it: a tone placed right is louder right, placed left is
 * louder left, a zero-gain low-pass filter silences it, a streamed sound plays its queue and reports it processed,
 * a looping sound keeps playing until stopped. Prints PASS/FAIL lines; exits 1 on any failure.
 *   build/al_test  (needs an output device; GitHub's Macs have a virtual one) */
#import <AVFoundation/AVFoundation.h>
#include <math.h>
#include <unistd.h>
#include "../audio/mcm_al.h"

ALCdevice *alcOpenDevice(const ALCchar *);
ALCcontext *alcCreateContext(ALCdevice *, const ALCint *);
ALCboolean alcMakeContextCurrent(ALCcontext *);
void alcDestroyContext(ALCcontext *);
ALCboolean alcCloseDevice(ALCdevice *);
ALCboolean alcIsExtensionPresent(ALCdevice *, const ALCchar *);
void *alcGetProcAddress(ALCdevice *, const ALCchar *);
void alcGetIntegerv(ALCdevice *, ALCenum, ALCsizei, ALCint *);
const ALCchar *alcGetString(ALCdevice *, ALCenum);
ALboolean alIsExtensionPresent(const ALchar *);
void alEnable(ALenum);
ALenum alGetError(void);
void alGenSources(ALsizei, ALuint *);
void alGenBuffers(ALsizei, ALuint *);
void alBufferData(ALuint, ALenum, const ALvoid *, ALsizei, ALsizei);
void alSourcei(ALuint, ALenum, ALint);
void alSourcef(ALuint, ALenum, ALfloat);
void alSource3f(ALuint, ALenum, ALfloat, ALfloat, ALfloat);
void alSource3i(ALuint, ALenum, ALint, ALint, ALint);
void alSourcePlay(ALuint);
void alSourceStop(ALuint);
void alGetSourcei(ALuint, ALenum, ALint *);
void alSourceQueueBuffers(ALuint, ALsizei, const ALuint *);
void alSourceUnqueueBuffers(ALuint, ALsizei, ALuint *);
void alListener3f(ALenum, ALfloat, ALfloat, ALfloat);
void alListenerfv(ALenum, const ALfloat *);
void alListenerf(ALenum, ALfloat);
void alGenFilters(ALsizei, ALuint *);
void alFilteri(ALuint, ALenum, ALint);
void alFilterf(ALuint, ALenum, ALfloat);
void alGenEffects(ALsizei, ALuint *);
void alEffecti(ALuint, ALenum, ALint);
void alEffectf(ALuint, ALenum, ALfloat);
void alGenAuxiliaryEffectSlots(ALsizei, ALuint *);
void alAuxiliaryEffectSloti(ALuint, ALenum, ALint);

static int fails;
static void check(int ok, const char *what) { printf("%s %s\n", ok ? "PASS" : "FAIL", what); if (!ok) fails++; }
static double now(void) { return CFAbsoluteTimeGetCurrent(); }

static short tone[48000];
static void makeTone(void) { for (int i = 0; i < 48000; i++) tone[i] = (short)(12000 * sin(2 * M_PI * 440 * i / 48000.0)); }

static ALint state(ALuint s) { ALint v = 0; alGetSourcei(s, AL_SOURCE_STATE, &v); return v; }
static void waitStopped(ALuint s, double secs) { double t = now(); while (state(s) == AL_PLAYING && now() - t < secs) usleep(10000); }

int main(void) {
    @autoreleasepool {
        char tap[] = "/tmp/mcm_al_test.caf";
        setenv("MCMETAL_AL_TAP", tap, 1);
        makeTone();
        ALCdevice *dev = alcOpenDevice(NULL);
        check(dev != NULL, "open the default output");
        if (!dev) return 1;
        printf("device: %s\n", alcGetString(dev, ALC_DEVICE_SPECIFIER));
        ALCcontext *ctx = alcCreateContext(dev, NULL);
        alcMakeContextCurrent(ctx);
        ALCint major = 0, minor = 0, sends = 0, connected = 0;
        alcGetIntegerv(dev, ALC_MAJOR_VERSION, 1, &major);
        alcGetIntegerv(dev, ALC_MINOR_VERSION, 1, &minor);
        alcGetIntegerv(dev, ALC_MAX_AUXILIARY_SENDS, 1, &sends);
        alcGetIntegerv(dev, ALC_CONNECTED, 1, &connected);
        check(major == 1 && minor == 1, "ALC 1.1");
        check(sends == 4, "4 auxiliary sends (Sound Physics uses 4)");
        check(connected == 1, "ALC_CONNECTED answers at once");
        check(alcIsExtensionPresent(dev, "ALC_EXT_EFX") && alcIsExtensionPresent(dev, "ALC_EXT_disconnect")
              && alcIsExtensionPresent(dev, "ALC_EXT_thread_local_context") && alcIsExtensionPresent(dev, "ALC_EXT_CAPTURE"),
              "ALC extensions Minecraft, Voice Chat and Sound Physics ask for");
        check(alIsExtensionPresent("AL_EXT_source_distance_model") && alIsExtensionPresent("AL_EXT_LINEAR_DISTANCE"),
              "AL extensions Minecraft requires");
        const char *fns[] = {"alcCaptureOpenDevice", "alcCaptureSamples", "alcSetThreadContext", "alGenEffects",
                             "alAuxiliaryEffectSloti", "alGetAuxiliaryEffectSlotfv", "alSourceUnqueueBuffers", "alGetBufferi",
                             "alSourcePlayv", "alGetDoublev", "alSpeedOfSound", "alGetListeneriv", NULL};
        int missing = 0;
        for (int i = 0; fns[i]; i++) if (!alcGetProcAddress(dev, fns[i])) { printf("  missing %s\n", fns[i]); missing++; }
        check(missing == 0, "entry points LWJGL looks up");
        alEnable(AL_SOURCE_DISTANCE_MODEL);
        ALfloat orient[6] = {0, 0, -1, 0, 1, 0};
        alListener3f(AL_POSITION, 0, 0, 0);
        alListenerfv(AL_ORIENTATION, orient);
        alListenerf(AL_GAIN, 1);

        ALuint buf, src[3];
        alGenBuffers(1, &buf);
        alBufferData(buf, AL_FORMAT_MONO16, tone, sizeof tone / 2, 48000); /* 0.5 s */
        alGenSources(3, src);
        for (int i = 0; i < 3; i++) { /* as Minecraft's linearAttenuation(16) */
            alSourcei(src[i], AL_DISTANCE_MODEL, AL_LINEAR_DISTANCE);
            alSourcef(src[i], AL_MAX_DISTANCE, 16);
            alSourcef(src[i], AL_ROLLOFF_FACTOR, 1);
            alSourcef(src[i], AL_REFERENCE_DISTANCE, 0);
        }
        double t0 = now();
        double seg[5][2];
        usleep(300000);
        /* 1: right */
        alSource3f(src[0], AL_POSITION, 4, 0, 0);
        alSourcei(src[0], AL_BUFFER, buf);
        seg[0][0] = now() - t0;
        alSourcePlay(src[0]);
        usleep(50000);
        check(state(src[0]) == AL_PLAYING, "a sound plays");
        waitStopped(src[0], 2);
        seg[0][1] = now() - t0;
        check(state(src[0]) == AL_STOPPED, "a one-shot sound stops by itself");
        usleep(200000);
        /* 2: left */
        alSource3f(src[1], AL_POSITION, -4, 0, 0);
        alSourcei(src[1], AL_BUFFER, buf);
        seg[1][0] = now() - t0;
        alSourcePlay(src[1]);
        waitStopped(src[1], 2);
        seg[1][1] = now() - t0;
        usleep(200000);
        /* 3: muffled to nothing by a zero-gain direct filter (Sound Physics' hold), with reverb sends set up */
        ALuint filt, eff, slot;
        alGenFilters(1, &filt);
        alFilteri(filt, AL_FILTER_TYPE, AL_FILTER_LOWPASS);
        alFilterf(filt, AL_LOWPASS_GAIN, 0);
        alGenEffects(1, &eff);
        alEffecti(eff, AL_EFFECT_TYPE, AL_EFFECT_EAXREVERB);
        alEffectf(eff, AL_EAXREVERB_DECAY_TIME, 1.5f);
        alGenAuxiliaryEffectSlots(1, &slot);
        alAuxiliaryEffectSloti(slot, AL_EFFECTSLOT_EFFECT, eff);
        alSource3f(src[2], AL_POSITION, 0, 0, -4);
        alSourcei(src[2], AL_BUFFER, buf);
        alSourcei(src[2], AL_DIRECT_FILTER, filt);
        seg[2][0] = now() - t0;
        alSourcePlay(src[2]);
        waitStopped(src[2], 2);
        seg[2][1] = now() - t0;
        usleep(200000);
        /* 4: a stream of 5 buffers of 0.1 s, as Minecraft's music and Voice Chat */
        ALuint sb[5], ss;
        alGenBuffers(5, sb);
        for (int i = 0; i < 5; i++) alBufferData(sb[i], AL_FORMAT_MONO16, tone, 4800 * 2, 48000);
        alGenSources(1, &ss);
        alSourcei(ss, AL_SOURCE_RELATIVE, AL_TRUE);
        alSource3f(ss, AL_POSITION, 0, 0, 0);
        alSourceQueueBuffers(ss, 5, sb);
        seg[3][0] = now() - t0;
        alSourcePlay(ss);
        double ts = now();
        ALint processed = 0;
        while (processed < 5 && now() - ts < 3) { usleep(10000); alGetSourcei(ss, AL_BUFFERS_PROCESSED, &processed); }
        seg[3][1] = now() - t0;
        check(processed == 5, "a stream reports its 5 buffers processed");
        ALuint back[5] = {0};
        alSourceUnqueueBuffers(ss, 5, back);
        check(back[0] == sb[0] && back[4] == sb[4] && alGetError() == AL_NO_ERROR, "processed buffers come back in order");
        usleep(100000);
        check(state(ss) == AL_STOPPED, "a stream that ran dry stops");
        /* 5: looping until stopped */
        alSourcei(src[0], AL_LOOPING, AL_TRUE);
        alSourcePlay(src[0]);
        usleep(1200000);
        check(state(src[0]) == AL_PLAYING, "a looping sound is still playing after 1.2 s of a 0.5 s buffer");
        alSourceStop(src[0]);
        check(state(src[0]) == AL_STOPPED, "stopping it");
        usleep(300000);
        alcMakeContextCurrent(NULL);
        alcDestroyContext(ctx);
        alcCloseDevice(dev);

        /* read back what played */
        NSError *err = nil;
        AVAudioFile *f = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:@(tap)] error:&err];
        check(f != nil, "the engine's output was recorded");
        if (!f) { printf("  %s\n", err.localizedDescription.UTF8String); return 1; }
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f.processingFormat frameCapacity:(AVAudioFrameCount)f.length];
        [f readIntoBuffer:pcm error:nil];
        double rate = f.processingFormat.sampleRate;
        int chans = (int)f.processingFormat.channelCount;
        printf("recorded %.2f s at %.0f Hz, %d channels\n", pcm.frameLength / rate, rate, chans);
        /* the recording starts when the engine starts, a moment before t0: find the first loud frame and line
         * segment 1 up with it */
        float **d = pcm.floatChannelData;
        long first = -1;
        for (long i = 0; i < (long)pcm.frameLength && first < 0; i++) if (fabsf(d[0][i]) + fabsf(d[chans - 1][i]) > 0.01f) first = i;
        check(first >= 0, "something was heard");
        if (first < 0) return 1;
        double shift = first / rate - seg[0][0];
        double rms[5][2];
        for (int s = 0; s < 4; s++) {
            long a = (long)((seg[s][0] + shift + 0.05) * rate), b = (long)((seg[s][1] + shift - 0.05) * rate);
            a = MAX(a, 0); b = MIN(b, (long)pcm.frameLength);
            for (int c = 0; c < 2; c++) {
                double e = 0;
                for (long i = a; i < b; i++) e += d[MIN(c, chans - 1)][i] * d[MIN(c, chans - 1)][i];
                rms[s][c] = b > a ? sqrt(e / (b - a)) : 0;
            }
            printf("segment %d: %.2f-%.2f s, rms left %.4f right %.4f\n", s + 1, seg[s][0], seg[s][1], rms[s][0], rms[s][1]);
        }
        check(rms[0][1] > 1.5 * rms[0][0], "a sound to the right is louder on the right");
        check(rms[1][0] > 1.5 * rms[1][1], "a sound to the left is louder on the left");
        check(rms[2][0] + rms[2][1] < 0.1 * (rms[0][0] + rms[0][1]), "a zero-gain low-pass filter silences it");
        check(rms[3][0] + rms[3][1] > 0.1 * (rms[0][0] + rms[0][1]), "the stream was heard");
        printf("%s: %d failed\n", fails ? "FAILED" : "ALL PASSED", fails);
        return fails ? 1 : 0;
    }
}
