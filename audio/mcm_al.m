/* libmcmetal-al.dylib: OpenAL 1.1 (+ ALC 1.1, EFX, ALC_EXT_thread_local_context, ALC_EXT_disconnect) on Apple's
 * AVAudioEngine, loaded instead of LWJGL's OpenAL Soft when MCMETAL_AUDIO_ENGINE=apple (MetalBootstrap sets
 * org.lwjgl.openal.libname). Minecraft, Simple Voice Chat and Sound Physics Remastered all talk to it unchanged.
 *
 * Each source plays through its own AVAudioPlayerNode. Mono sources go into one AVAudioEnvironmentNode: Apple's
 * spatializer (personalised HRTF on headphones, AirPods head tracking, MCMETAL_AUDIO_HEADTRACK=0 turns that off),
 * with its built-in reverb. Stereo sources and sounds attached to the listener (music, menus) go into a plain mixer.
 * OpenAL's own rules stay ours: distance attenuation (per source, AL_EXT_source_distance_model) is computed here
 * every 10 ms and set as the node's volume (the environment's own attenuation is off); a low-pass direct filter
 * becomes "obstruction"; auxiliary sends to reverb slots become the node's reverb blend, and the environment reverb
 * follows the decay time the busiest slot asks for.
 * The device follows the Mac's default output by itself, so ALC_CONNECTED is always true and Minecraft's slow
 * device check never blocks.
 * Mic capture (Voice Chat) uses an AudioQueue in the requested format.
 * MCMETAL_AL_TAP=FILE.caf records what the engine plays (tests). MCMETAL_AL_LOG=1 logs objects and states.
 */
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include "mcm_al.h"

static void lg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void lg(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[mcmetal-al] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}
static int verbose(void) {
    static int v = -1;
    if (v < 0) v = getenv("MCMETAL_AL_LOG") != NULL;
    return v;
}

/* ---------------------------------------------------------------- objects */

@interface MCBuffer : NSObject
@property ALuint name;
@property(strong) AVAudioPCMBuffer *pcm; /* float32, deinterleaved */
@property ALint freq, bits, channels, size;
@end
@implementation MCBuffer
@end

@interface MCFilter : NSObject
@property ALuint name;
@property ALint type;
@property float gain, gainHF;
@end
@implementation MCFilter
- (instancetype)init { if ((self = [super init])) { _gain = 1; _gainHF = 1; } return self; }
@end

@interface MCEffect : NSObject
@property ALuint name;
@property ALint type;
@property float gain, decay;
@end
@implementation MCEffect
- (instancetype)init { if ((self = [super init])) { _gain = 0.32f; _decay = 1.49f; } return self; }
@end

@interface MCSlot : NSObject
@property ALuint name;
@property ALuint effect;
@property ALint effectType;
@property float gain, effectGain, decay;
@property float load; /* how much playing sources send to it this tick */
@end
@implementation MCSlot
- (instancetype)init { if ((self = [super init])) { _gain = 1; } return self; }
@end

typedef struct { float gain, gainHF; ALint type; } FilterParams;

@class MCDevice;
@interface MCSource : NSObject
@property ALuint name;
@property(weak) MCDevice *dev;
@property ALCcontext *ctx; /* the context it was made in (listener, distance model) */
@property float gain, pitch, minGain, maxGain, refDist, rolloff, maxDist, airAbsorption;
@property float px, py, pz;
@property ALint relative, looping, model, state;
@property ALuint buffer; /* static buffer */
@property(strong) NSMutableArray<NSNumber *> *queue; /* queued buffer names, oldest first */
@property ALint processed; /* first `processed` of queue have played */
@property ALint scheduled; /* how many of queue were handed to the node */
@property unsigned gen; /* bumped on every play/stop: completion callbacks of older runs are ignored */
@property(strong) AVAudioPlayerNode *node;
@property(strong) AVAudioFormat *nodeFormat;
@property BOOL toEnv;
@property FilterParams direct;
@property ALuint sendSlot0, sendSlot1, sendSlot2, sendSlot3;
@property FilterParams send0, send1, send2, send3;
@property double startSample; /* buffer frame the current run began at (offsets) */
@end
@implementation MCSource
- (instancetype)init {
    if ((self = [super init])) {
        _gain = 1; _pitch = 1; _minGain = 0; _maxGain = 1; _refDist = 1; _rolloff = 1; _maxDist = FLT_MAX;
        _model = AL_INVERSE_DISTANCE_CLAMPED; _state = AL_INITIAL;
        _queue = [NSMutableArray array];
        FilterParams none = {1, 1, AL_FILTER_NULL};
        _direct = none; _send0 = none; _send1 = none; _send2 = none; _send3 = none;
    }
    return self;
}
@end

@interface MCDevice : NSObject
@property(strong) AVAudioEngine *engine;
@property(strong) AVAudioEnvironmentNode *env;
@property(strong) AVAudioMixerNode *flat;
@property(strong) NSString *deviceName;
@property AudioDeviceID deviceID; /* 0 = follow the system default */
@property BOOL running;
@property(strong) id observer;
@property(strong) AVAudioFile *tap;
@property AVAudioUnitReverbPreset preset;
@property int presetSet;
@end
@implementation MCDevice
@end

struct mcm_device { void *dev; int isCapture; ALCenum error; /* capture */ AudioQueueRef queue; unsigned char *ring;
    size_t ringSize, ringHead, ringFill; int frameBytes; int started; };
struct mcm_context {
    struct mcm_device *device;
    float lx, ly, lz, lgain;
    float atx, aty, atz, upx, upy, upz;
    ALenum model;
    int sourceModel;
    ALenum error;
    float doppler, speedOfSound;
};

/* One lock for everything: OpenAL calls come from the render thread, the sound engine thread, Voice Chat's
 * threads and Sound Physics' thread. AVAudioEngine callbacks never take it directly: they hop to `q` first. */
static NSRecursiveLock *lock;
static dispatch_queue_t q;
static NSMutableDictionary<NSNumber *, MCSource *> *sources;
static NSMutableDictionary<NSNumber *, MCBuffer *> *buffers;
static NSMutableDictionary<NSNumber *, MCFilter *> *filters;
static NSMutableDictionary<NSNumber *, MCEffect *> *effects;
static NSMutableDictionary<NSNumber *, MCSlot *> *slots;
static ALuint nextName = 1;
static ALCcontext *current;
static ALCcontext *contexts[16]; /* every live context, for the 10 ms update */
static pthread_key_t threadCtx;
static ALCenum globalAlcError;
static dispatch_source_t ticker;

static void setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSRecursiveLock new];
        q = dispatch_queue_create("mcmetal-al", DISPATCH_QUEUE_SERIAL);
        sources = [NSMutableDictionary dictionary];
        buffers = [NSMutableDictionary dictionary];
        filters = [NSMutableDictionary dictionary];
        effects = [NSMutableDictionary dictionary];
        slots = [NSMutableDictionary dictionary];
        pthread_key_create(&threadCtx, NULL);
    });
}
#define LOCK() do { setup(); [lock lock]; } while (0)
#define UNLOCK() [lock unlock]

static ALCcontext *ctx(void) {
    setup();
    ALCcontext *t = pthread_getspecific(threadCtx);
    return t ? t : current;
}
static void seterr(ALenum e) {
    ALCcontext *c = ctx();
    if (c && c->error == AL_NO_ERROR) c->error = e;
}
static MCDevice *devOf(ALCcontext *c) { return c ? (__bridge MCDevice *)c->device->dev : nil; }

/* ---------------------------------------------------------------- spatial maths */

static float clampf(float v, float lo, float hi) { return v < lo ? lo : v > hi ? hi : v; }

static float attenuation(MCSource *s, ALCcontext *c, float d) {
    ALenum m = c->sourceModel ? s.model : c->model;
    float ref = s.refDist, roll = s.rolloff, mx = s.maxDist;
    switch (m) {
    case AL_INVERSE_DISTANCE_CLAMPED: d = clampf(d, ref, fmaxf(ref, mx)); /* fall through */
    case AL_INVERSE_DISTANCE:
        if (ref + roll * (d - ref) <= 0) return 1;
        return ref / (ref + roll * (d - ref));
    case AL_LINEAR_DISTANCE_CLAMPED: d = clampf(d, ref, fmaxf(ref, mx)); /* fall through */
    case AL_LINEAR_DISTANCE:
        if (mx <= ref) return 1;
        return clampf(1 - roll * (d - ref) / (mx - ref), 0, 1);
    case AL_EXPONENT_DISTANCE_CLAMPED: d = clampf(d, ref, fmaxf(ref, mx)); /* fall through */
    case AL_EXPONENT_DISTANCE:
        if (d <= 0 || ref <= 0) return 1;
        return powf(d / ref, -roll);
    default: return 1;
    }
}

/* world position of a source (listener-relative ones turned with the listener) */
static void worldPos(MCSource *s, ALCcontext *c, float *x, float *y, float *z) {
    if (!s.relative) { *x = s.px; *y = s.py; *z = s.pz; return; }
    float fx = c->atx, fy = c->aty, fz = c->atz, ux = c->upx, uy = c->upy, uz = c->upz;
    float rx = fy * uz - fz * uy, ry = fz * ux - fx * uz, rz = fx * uy - fy * ux; /* right = at x up */
    float rl = sqrtf(rx * rx + ry * ry + rz * rz);
    if (rl > 0) { rx /= rl; ry /= rl; rz /= rl; }
    *x = c->lx + s.px * rx + s.py * ux - s.pz * fx;
    *y = c->ly + s.px * ry + s.py * uy - s.pz * fy;
    *z = c->lz + s.px * rz + s.py * uz - s.pz * fz;
}

static FilterParams sendOf(MCSource *s, int i) {
    switch (i) { case 0: return s.send0; case 1: return s.send1; case 2: return s.send2; default: return s.send3; }
}
static ALuint slotOf(MCSource *s, int i) {
    switch (i) { case 0: return s.sendSlot0; case 1: return s.sendSlot1; case 2: return s.sendSlot2; default: return s.sendSlot3; }
}

/* Volume, position, pitch, muffling and reverb of one source, from its OpenAL state. Lock held. */
static void apply(MCSource *s) {
    ALCcontext *c = s.ctx;
    if (!s.node || !c) return;
    float x, y, z;
    worldPos(s, c, &x, &y, &z);
    float dx = x - c->lx, dy = y - c->ly, dz = z - c->lz;
    float g = clampf(s.gain * attenuation(s, c, sqrtf(dx * dx + dy * dy + dz * dz)), s.minGain, s.maxGain);
    FilterParams d = s.direct;
    if (d.type == AL_FILTER_LOWPASS) g *= d.gain;
    s.node.volume = g;
    if (!s.toEnv) return;
    s.node.position = AVAudioMake3DPoint(x, y, z);
    s.node.rate = clampf(s.pitch, 0.5f, 2.0f);
    s.node.obstruction = d.type == AL_FILTER_LOWPASS ? clampf(20 * log10f(fmaxf(d.gainHF, 1e-5f)), -100, 0) : 0;
    float blend = 0;
    for (int i = 0; i < 4; i++) {
        MCSlot *sl = slots[@(slotOf(s, i))];
        if (!sl || (sl.effectType != AL_EFFECT_EAXREVERB && sl.effectType != AL_EFFECT_REVERB)) continue;
        FilterParams f = sendOf(s, i);
        float w = sl.gain * (f.type == AL_FILTER_LOWPASS ? f.gain : 1);
        blend += w;
        if (s.state == AL_PLAYING) sl.load += w * g;
    }
    s.node.reverbBlend = clampf(blend, 0, 1);
}

/* The environment's one reverb follows the decay time of the slot that playing sounds send the most to. */
static void pickReverb(MCDevice *d) {
    MCSlot *best = nil;
    for (MCSlot *sl in slots.allValues) {
        if (!best || sl.load > best.load) best = sl;
    }
    if (!best || best.load <= 0) return;
    float t = best.decay;
    AVAudioUnitReverbPreset p = t < 0.4f ? AVAudioUnitReverbPresetSmallRoom
                                     : t < 1.0f ? AVAudioUnitReverbPresetMediumRoom
                                     : t < 2.0f ? AVAudioUnitReverbPresetLargeRoom
                                     : t < 3.5f ? AVAudioUnitReverbPresetMediumHall
                                                : AVAudioUnitReverbPresetLargeHall;
    if (!d.presetSet || d.preset != p) {
        [d.env.reverbParameters loadFactoryReverbPreset:p];
        d.preset = p;
        d.presetSet = 1;
        if (verbose()) lg("reverb preset %ld (decay %.2f s)", (long)p, t);
    }
    for (MCSlot *sl in slots.allValues) sl.load = 0;
}

static void tick(void) {
    LOCK();
    for (int i = 0; i < 16; i++) { /* each device's listener is its context's (Minecraft and Voice Chat: one each) */
        ALCcontext *c = contexts[i];
        MCDevice *d = devOf(c);
        if (!c || !d) continue;
        d.engine.mainMixerNode.outputVolume = c->lgain;
        d.env.listenerPosition = AVAudioMake3DPoint(c->lx, c->ly, c->lz);
        d.env.listenerVectorOrientation = AVAudioMake3DVectorOrientation(AVAudioMake3DVector(c->atx, c->aty, c->atz),
                                                                         AVAudioMake3DVector(c->upx, c->upy, c->upz));
    }
    for (MCSource *s in sources.allValues)
        if (s.state == AL_PLAYING) apply(s);
    static int n;
    if (++n % 25 == 0) /* four times a second */
        for (int i = 0; i < 16; i++)
            if (contexts[i] && devOf(contexts[i])) pickReverb(devOf(contexts[i]));
    UNLOCK();
}

static void restart(MCSource *s);

/* ---------------------------------------------------------------- engine */

static void connectGraph(MCDevice *d) {
    AVAudioEngine *e = d.engine;
    AVAudioFormat *hw = [e.outputNode inputFormatForBus:0];
    double rate = hw.sampleRate > 0 ? hw.sampleRate : 48000;
    AVAudioFormat *stereo = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    [e connect:d.env to:e.mainMixerNode format:stereo];
    [e connect:d.flat to:e.mainMixerNode format:stereo];
}

static void startEngine(MCDevice *d) {
    NSError *err = nil;
    [d.engine prepare];
    d.running = [d.engine startAndReturnError:&err];
    if (!d.running) lg("could not start the audio engine: %s", err.localizedDescription.UTF8String);
}

static BOOL setOutputDevice(MCDevice *d, AudioDeviceID id) {
    if (!id) return YES;
    AudioUnit au = d.engine.outputNode.audioUnit;
    return AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, sizeof id) == noErr;
}

/* The output changed (headphones in or out, AirPods connected): the engine stopped itself. Reconnect at the new
 * format and carry on; looping and streamed sounds start again, one-shot sounds that were cut off end. */
static void configurationChanged(MCDevice *d) {
    LOCK();
    if (verbose()) lg("output changed, restarting the engine");
    connectGraph(d);
    for (MCSource *s in sources.allValues) {
        if (s.dev != d || !s.node) continue;
        if (s.state == AL_PLAYING && !s.looping && s.queue.count == 0) {
            s.state = AL_STOPPED;
            s.gen++;
        }
    }
    startEngine(d);
    for (MCSource *s in sources.allValues) {
        if (s.dev != d || !s.node || s.state != AL_PLAYING) continue;
        restart(s);
    }
    UNLOCK();
}

/* ---------------------------------------------------------------- device names */

static NSArray<NSDictionary *> *audioDevices(BOOL input) {
    NSMutableArray *out = [NSMutableArray array];
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) != noErr) return out;
    int n = size / sizeof(AudioDeviceID);
    AudioDeviceID ids[n > 0 ? n : 1];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) != noErr) return out;
    for (int i = 0; i < n; i++) {
        AudioObjectPropertyAddress sa = {kAudioDevicePropertyStreams, input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        UInt32 ss = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &sa, 0, NULL, &ss) != noErr || ss == 0) continue;
        CFStringRef name = NULL;
        UInt32 ns = sizeof name;
        AudioObjectPropertyAddress na = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        if (AudioObjectGetPropertyData(ids[i], &na, 0, NULL, &ns, &name) != noErr || !name) continue;
        [out addObject:@{@"id": @(ids[i]), @"name": (__bridge_transfer NSString *)name}];
    }
    return out;
}
static NSString *defaultDeviceName(BOOL input) {
    AudioDeviceID id = 0;
    UInt32 size = sizeof id;
    AudioObjectPropertyAddress a = {input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, &id) == noErr)
        for (NSDictionary *dv in audioDevices(input))
            if ([dv[@"id"] unsignedIntValue] == id) return dv[@"name"];
    return input ? @"Default input" : @"Default output";
}
/* a list of C strings, each 0-terminated, ending with an extra 0 (ALC device lists); kept per kind */
static const ALCchar *nameList(NSArray<NSString *> *names, int slot) {
    static char *lists[8];
    NSMutableData *m = [NSMutableData data];
    for (NSString *n in names) [m appendBytes:n.UTF8String length:strlen(n.UTF8String) + 1];
    [m appendBytes:"\0" length:1];
    free(lists[slot]);
    lists[slot] = malloc(m.length);
    memcpy(lists[slot], m.bytes, m.length);
    return lists[slot];
}
static const ALCchar *keep(NSString *s, int slot) {
    static char *strs[8];
    free(strs[slot]);
    strs[slot] = strdup(s.UTF8String);
    return strs[slot];
}

/* ---------------------------------------------------------------- ALC: devices and contexts */

AL_API ALCdevice *alcOpenDevice(const ALCchar *name) {
    LOCK();
    MCDevice *d = [MCDevice new];
    d.engine = [AVAudioEngine new];
    d.env = [AVAudioEnvironmentNode new];
    d.flat = [AVAudioMixerNode new];
    d.deviceName = name ? @(name) : defaultDeviceName(NO);
    if (name) {
        for (NSDictionary *dv in audioDevices(NO))
            if ([dv[@"name"] isEqualToString:@(name)]) d.deviceID = [dv[@"id"] unsignedIntValue];
        if (!d.deviceID && strcmp(name, defaultDeviceName(NO).UTF8String) != 0) {
            UNLOCK();
            return NULL; /* asked for a device that isn't there: as OpenAL Soft */
        }
    }
    [d.engine attachNode:d.env];
    [d.engine attachNode:d.flat];
    setOutputDevice(d, d.deviceID);
    AVAudioEnvironmentDistanceAttenuationParameters *att = d.env.distanceAttenuationParameters;
    att.distanceAttenuationModel = AVAudioEnvironmentDistanceAttenuationModelLinear;
    att.rolloffFactor = 0; /* attenuation is ours (OpenAL's per-source models) */
    att.referenceDistance = 1;
    att.maximumDistance = 100000;
    d.env.reverbParameters.enable = YES;
    d.env.reverbParameters.level = 0;
    [d.env.reverbParameters loadFactoryReverbPreset:AVAudioUnitReverbPresetMediumRoom];
    if (@available(macOS 15.0, *)) {
        const char *ht = getenv("MCMETAL_AUDIO_HEADTRACK");
        d.env.listenerHeadTrackingEnabled = !(ht && !strcmp(ht, "0"));
    }
    connectGraph(d);
    const char *tap = getenv("MCMETAL_AL_TAP");
    if (tap && *tap) {
        AVAudioFormat *f = [d.engine.mainMixerNode outputFormatForBus:0];
        NSError *err = nil;
        d.tap = [[AVAudioFile alloc] initForWriting:[NSURL fileURLWithPath:@(tap)] settings:f.settings error:&err];
        if (d.tap) {
            AVAudioFile *file = d.tap;
            [d.engine.mainMixerNode installTapOnBus:0 bufferSize:4096 format:f block:^(AVAudioPCMBuffer *b, AVAudioTime *when) {
                [file writeFromBuffer:b error:nil];
            }];
        } else lg("MCMETAL_AL_TAP: can't write %s: %s", tap, err.localizedDescription.UTF8String);
    }
    __weak MCDevice *wd = d;
    d.observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
        object:d.engine queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(q, ^{ MCDevice *sd = wd; if (sd) configurationChanged(sd); });
        }];
    startEngine(d);
    if (!ticker) {
        ticker = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(ticker, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(ticker, ^{ tick(); });
        dispatch_resume(ticker);
    }
    struct mcm_device *dev = calloc(1, sizeof *dev);
    dev->dev = (__bridge_retained void *)d;
    lg("Apple audio engine on %s%s", d.deviceName.UTF8String, d.running ? "" : " (not started)");
    UNLOCK();
    return dev;
}

AL_API ALCboolean alcCloseDevice(ALCdevice *dev) {
    if (!dev) return AL_FALSE;
    LOCK();
    if (dev->isCapture) { UNLOCK(); return AL_FALSE; }
    MCDevice *d = (__bridge_transfer MCDevice *)dev->dev;
    if (d.tap) [d.engine.mainMixerNode removeTapOnBus:0];
    d.tap = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:d.observer];
    [d.engine stop];
    for (NSNumber *k in sources.allKeys) if (sources[k].dev == d) [sources removeObjectForKey:k];
    free(dev);
    UNLOCK();
    return AL_TRUE;
}

AL_API ALCcontext *alcCreateContext(ALCdevice *dev, const ALCint *attrs) {
    if (!dev || dev->isCapture) { globalAlcError = ALC_INVALID_DEVICE; return NULL; }
    ALCcontext *c = calloc(1, sizeof *c);
    c->device = dev;
    c->lgain = 1;
    c->atz = -1;
    c->upy = 1;
    c->model = AL_INVERSE_DISTANCE_CLAMPED;
    c->doppler = 1;
    c->speedOfSound = 343.3f;
    LOCK();
    for (int i = 0; i < 16; i++) if (!contexts[i]) { contexts[i] = c; break; }
    UNLOCK();
    return c;
}
AL_API ALCboolean alcMakeContextCurrent(ALCcontext *c) { LOCK(); current = c; UNLOCK(); return AL_TRUE; }
AL_API void alcProcessContext(ALCcontext *c) {}
AL_API void alcSuspendContext(ALCcontext *c) {}
AL_API void alcDestroyContext(ALCcontext *c) {
    LOCK();
    if (current == c) current = NULL;
    if (pthread_getspecific(threadCtx) == c) pthread_setspecific(threadCtx, NULL);
    for (int i = 0; i < 16; i++) if (contexts[i] == c) contexts[i] = NULL;
    for (MCSource *s in sources.allValues) if (s.ctx == c) s.ctx = NULL;
    free(c);
    UNLOCK();
}
AL_API ALCcontext *alcGetCurrentContext(void) { return ctx(); }
AL_API ALCdevice *alcGetContextsDevice(ALCcontext *c) { return c ? c->device : NULL; }
AL_API ALCboolean alcSetThreadContext(ALCcontext *c) { setup(); pthread_setspecific(threadCtx, c); return AL_TRUE; }
AL_API ALCcontext *alcGetThreadContext(void) { setup(); return pthread_getspecific(threadCtx); }

AL_API ALCenum alcGetError(ALCdevice *dev) {
    ALCenum e;
    if (dev) { e = dev->error; dev->error = ALC_NO_ERROR; }
    else { e = globalAlcError; globalAlcError = ALC_NO_ERROR; }
    return e;
}

static const char *ALC_EXTS = "ALC_ENUMERATE_ALL_EXT ALC_ENUMERATION_EXT ALC_EXT_CAPTURE ALC_EXT_disconnect ALC_EXT_EFX ALC_EXT_thread_local_context";
static const char *AL_EXTS = "AL_EXT_source_distance_model AL_EXT_LINEAR_DISTANCE AL_EXT_EXPONENT_DISTANCE AL_EXT_FLOAT32 AL_EXT_OFFSET";

static int hasWord(const char *list, const char *w) {
    size_t n = strlen(w);
    for (const char *p = list; (p = strcasestr(p, w)); p += n)
        if ((p == list || p[-1] == ' ') && (p[n] == ' ' || p[n] == 0)) return 1;
    return 0;
}
AL_API ALCboolean alcIsExtensionPresent(ALCdevice *dev, const ALCchar *name) { return name && hasWord(ALC_EXTS, name); }
AL_API void *alcGetProcAddress(ALCdevice *dev, const ALCchar *name) { return name ? dlsym(RTLD_SELF, name) : NULL; }
AL_API ALCenum alcGetEnumValue(ALCdevice *dev, const ALCchar *name) { return 0; }

AL_API const ALCchar *alcGetString(ALCdevice *dev, ALCenum p) {
    LOCK();
    const ALCchar *r = NULL;
    switch (p) {
    case ALC_NO_ERROR: r = "No Error"; break;
    case ALC_INVALID_DEVICE: r = "Invalid Device"; break;
    case ALC_INVALID_CONTEXT: r = "Invalid Context"; break;
    case ALC_INVALID_ENUM: r = "Invalid Enum"; break;
    case ALC_INVALID_VALUE: r = "Invalid Value"; break;
    case ALC_OUT_OF_MEMORY: r = "Out of Memory"; break;
    case ALC_EXTENSIONS: r = ALC_EXTS; break;
    case ALC_DEFAULT_DEVICE_SPECIFIER:
    case ALC_DEFAULT_ALL_DEVICES_SPECIFIER: r = keep(defaultDeviceName(NO), 0); break;
    case ALC_CAPTURE_DEFAULT_DEVICE_SPECIFIER: r = keep(defaultDeviceName(YES), 1); break;
    case ALC_DEVICE_SPECIFIER:
    case ALC_ALL_DEVICES_SPECIFIER:
        if (dev && !dev->isCapture) r = keep(((__bridge MCDevice *)dev->dev).deviceName, 2);
        else r = nameList([audioDevices(NO) valueForKey:@"name"], 0);
        break;
    case ALC_CAPTURE_DEVICE_SPECIFIER:
        if (dev && dev->isCapture) r = keep(defaultDeviceName(YES), 3);
        else r = nameList([audioDevices(YES) valueForKey:@"name"], 1);
        break;
    default: if (dev) dev->error = ALC_INVALID_ENUM; else globalAlcError = ALC_INVALID_ENUM;
    }
    UNLOCK();
    return r;
}

static size_t captureFrames(ALCdevice *dev);
AL_API void alcGetIntegerv(ALCdevice *dev, ALCenum p, ALCsizei n, ALCint *v) {
    if (!v || n <= 0) return;
    LOCK();
    double rate = 48000;
    if (dev && !dev->isCapture) rate = [((__bridge MCDevice *)dev->dev).engine.outputNode inputFormatForBus:0].sampleRate;
    ALCint attrs[] = {ALC_FREQUENCY, (ALCint)rate, ALC_REFRESH, 100, ALC_SYNC, 0, ALC_MONO_SOURCES, 255,
                      ALC_STEREO_SOURCES, 255, ALC_MAX_AUXILIARY_SENDS, 4, 0};
    switch (p) {
    case ALC_MAJOR_VERSION: v[0] = 1; break;
    case ALC_MINOR_VERSION: v[0] = 1; break;
    case ALC_EFX_MAJOR_VERSION: v[0] = 1; break;
    case ALC_EFX_MINOR_VERSION: v[0] = 0; break;
    case ALC_MAX_AUXILIARY_SENDS: v[0] = 4; break;
    case ALC_FREQUENCY: v[0] = (ALCint)rate; break;
    case ALC_REFRESH: v[0] = 100; break;
    case ALC_SYNC: v[0] = 0; break;
    case ALC_MONO_SOURCES: v[0] = 255; break;
    case ALC_STEREO_SOURCES: v[0] = 255; break;
    case ALC_CONNECTED: v[0] = 1; break; /* the engine follows the Mac's output itself */
    case ALC_ATTRIBUTES_SIZE: v[0] = (ALCint)(sizeof attrs / sizeof attrs[0]); break;
    case ALC_ALL_ATTRIBUTES:
        memcpy(v, attrs, sizeof(ALCint) * MIN((size_t)n, sizeof attrs / sizeof attrs[0]));
        break;
    case ALC_CAPTURE_SAMPLES: v[0] = dev && dev->isCapture ? (ALCint)captureFrames(dev) : 0; break;
    default: if (dev) dev->error = ALC_INVALID_ENUM; else globalAlcError = ALC_INVALID_ENUM;
    }
    UNLOCK();
}

/* ---------------------------------------------------------------- ALC capture (Voice Chat's microphone) */

static size_t captureFrames(ALCdevice *dev) { return dev->ringFill / dev->frameBytes; }

static void captureCallback(void *ud, AudioQueueRef aq, AudioQueueBufferRef b, const AudioTimeStamp *t, UInt32 np, const AudioStreamPacketDescription *pd) {
    ALCdevice *dev = ud;
    LOCK();
    const unsigned char *src = b->mAudioData;
    size_t n = b->mAudioDataByteSize;
    for (size_t i = 0; i < n; i++) { /* ring buffer: the oldest audio goes when it's full */
        dev->ring[(dev->ringHead + dev->ringFill) % dev->ringSize] = src[i];
        if (dev->ringFill < dev->ringSize) dev->ringFill++;
        else dev->ringHead = (dev->ringHead + 1) % dev->ringSize;
    }
    UNLOCK();
    if (dev->started) AudioQueueEnqueueBuffer(aq, b, 0, NULL);
}

AL_API ALCdevice *alcCaptureOpenDevice(const ALCchar *name, ALCuint freq, ALCenum format, ALCsizei bufferSize) {
    int ch = format == AL_FORMAT_STEREO16 || format == AL_FORMAT_STEREO8 || format == AL_FORMAT_STEREO_FLOAT32 ? 2 : 1;
    int bits = format == AL_FORMAT_MONO8 || format == AL_FORMAT_STEREO8 ? 8 : format == AL_FORMAT_MONO_FLOAT32 || format == AL_FORMAT_STEREO_FLOAT32 ? 32 : 16;
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = freq;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = bits == 32 ? kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                   : bits == 16 ? kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked : kAudioFormatFlagIsPacked;
    f.mChannelsPerFrame = ch;
    f.mBitsPerChannel = bits;
    f.mBytesPerFrame = f.mBytesPerPacket = ch * bits / 8;
    f.mFramesPerPacket = 1;
    ALCdevice *dev = calloc(1, sizeof *dev);
    dev->isCapture = 1;
    dev->frameBytes = f.mBytesPerFrame;
    dev->ringSize = (size_t)MAX(bufferSize, 4096) * f.mBytesPerFrame;
    dev->ring = malloc(dev->ringSize);
    if (AudioQueueNewInput(&f, captureCallback, dev, NULL, kCFRunLoopCommonModes, 0, &dev->queue) != noErr) {
        lg("could not open the microphone");
        free(dev->ring);
        free(dev);
        globalAlcError = ALC_INVALID_VALUE;
        return NULL;
    }
    if (name) {
        for (NSDictionary *dv in audioDevices(YES)) {
            if (![dv[@"name"] isEqualToString:@(name)]) continue;
            AudioDeviceID id = [dv[@"id"] unsignedIntValue];
            CFStringRef uid = NULL;
            UInt32 us = sizeof uid;
            AudioObjectPropertyAddress ua = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            if (AudioObjectGetPropertyData(id, &ua, 0, NULL, &us, &uid) == noErr && uid) {
                AudioQueueSetProperty(dev->queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof uid);
                CFRelease(uid);
            }
        }
    }
    UInt32 bytes = (UInt32)(f.mBytesPerFrame * (freq / 50 > 0 ? freq / 50 : 960)); /* 20 ms buffers */
    for (int i = 0; i < 4; i++) {
        AudioQueueBufferRef b;
        if (AudioQueueAllocateBuffer(dev->queue, bytes, &b) == noErr) AudioQueueEnqueueBuffer(dev->queue, b, 0, NULL);
    }
    return dev;
}
AL_API ALCboolean alcCaptureCloseDevice(ALCdevice *dev) {
    if (!dev || !dev->isCapture) return AL_FALSE;
    dev->started = 0;
    AudioQueueDispose(dev->queue, true);
    free(dev->ring);
    free(dev);
    return AL_TRUE;
}
AL_API void alcCaptureStart(ALCdevice *dev) {
    if (!dev || !dev->isCapture) return;
    dev->started = 1;
    AudioQueueStart(dev->queue, NULL);
}
AL_API void alcCaptureStop(ALCdevice *dev) {
    if (!dev || !dev->isCapture) return;
    dev->started = 0;
    AudioQueuePause(dev->queue);
}
AL_API void alcCaptureSamples(ALCdevice *dev, ALCvoid *out, ALCsizei frames) {
    if (!dev || !dev->isCapture) return;
    LOCK();
    size_t n = (size_t)frames * dev->frameBytes;
    if (n > dev->ringFill) { dev->error = ALC_INVALID_VALUE; UNLOCK(); return; }
    unsigned char *o = out;
    for (size_t i = 0; i < n; i++) o[i] = dev->ring[(dev->ringHead + i) % dev->ringSize];
    dev->ringHead = (dev->ringHead + n) % dev->ringSize;
    dev->ringFill -= n;
    UNLOCK();
}

/* ---------------------------------------------------------------- AL state */

AL_API ALenum alGetError(void) {
    LOCK();
    ALCcontext *c = ctx();
    ALenum e = c ? c->error : AL_INVALID_OPERATION;
    if (c) c->error = AL_NO_ERROR;
    UNLOCK();
    return e;
}
AL_API void alEnable(ALenum cap) { LOCK(); ALCcontext *c = ctx(); if (c && cap == AL_SOURCE_DISTANCE_MODEL) c->sourceModel = 1; else seterr(AL_INVALID_ENUM); UNLOCK(); }
AL_API void alDisable(ALenum cap) { LOCK(); ALCcontext *c = ctx(); if (c && cap == AL_SOURCE_DISTANCE_MODEL) c->sourceModel = 0; else seterr(AL_INVALID_ENUM); UNLOCK(); }
AL_API ALboolean alIsEnabled(ALenum cap) { ALCcontext *c = ctx(); return c && cap == AL_SOURCE_DISTANCE_MODEL && c->sourceModel; }
AL_API ALboolean alIsExtensionPresent(const ALchar *name) { return name && hasWord(AL_EXTS, name); }
AL_API void *alGetProcAddress(const ALchar *name) { return name ? dlsym(RTLD_SELF, name) : NULL; }
AL_API ALenum alGetEnumValue(const ALchar *name) { return 0; }
AL_API const ALchar *alGetString(ALenum p) {
    switch (p) {
    case AL_VENDOR: return "mcmetal";
    case AL_VERSION: return "1.1 mcmetal (AVAudioEngine)";
    case AL_RENDERER: return "Apple AVAudioEngine";
    case AL_EXTENSIONS: return AL_EXTS;
    case AL_NO_ERROR: return "No Error";
    case AL_INVALID_NAME: return "Invalid Name";
    case AL_INVALID_ENUM: return "Invalid Enum";
    case AL_INVALID_VALUE: return "Invalid Value";
    case AL_INVALID_OPERATION: return "Invalid Operation";
    case AL_OUT_OF_MEMORY: return "Out of Memory";
    default: seterr(AL_INVALID_ENUM); return NULL;
    }
}
AL_API void alDistanceModel(ALenum m) { LOCK(); ALCcontext *c = ctx(); if (c) c->model = m; UNLOCK(); }
AL_API void alDopplerFactor(ALfloat v) { LOCK(); ALCcontext *c = ctx(); if (c) c->doppler = v; UNLOCK(); }
AL_API void alDopplerVelocity(ALfloat v) {}
AL_API void alSpeedOfSound(ALfloat v) { LOCK(); ALCcontext *c = ctx(); if (c) c->speedOfSound = v; UNLOCK(); }

static double stateValue(ALenum p) {
    ALCcontext *c = ctx();
    if (!c) return 0;
    switch (p) {
    case AL_DISTANCE_MODEL: return c->model;
    case AL_DOPPLER_FACTOR: return c->doppler;
    case AL_DOPPLER_VELOCITY: return 1;
    case AL_SPEED_OF_SOUND: return c->speedOfSound;
    default: seterr(AL_INVALID_ENUM); return 0;
    }
}
AL_API ALboolean alGetBoolean(ALenum p) { return stateValue(p) != 0; }
AL_API ALint alGetInteger(ALenum p) { return (ALint)stateValue(p); }
AL_API ALfloat alGetFloat(ALenum p) { return (ALfloat)stateValue(p); }
AL_API ALdouble alGetDouble(ALenum p) { return stateValue(p); }
AL_API void alGetBooleanv(ALenum p, ALboolean *v) { if (v) *v = alGetBoolean(p); }
AL_API void alGetIntegerv(ALenum p, ALint *v) { if (v) *v = alGetInteger(p); }
AL_API void alGetFloatv(ALenum p, ALfloat *v) { if (v) *v = alGetFloat(p); }
AL_API void alGetDoublev(ALenum p, ALdouble *v) { if (v) *v = alGetDouble(p); }

/* ---------------------------------------------------------------- listener */

AL_API void alListenerf(ALenum p, ALfloat v) {
    LOCK();
    ALCcontext *c = ctx();
    if (c && p == AL_GAIN) c->lgain = v;
    else if (c && p != AL_METERS_PER_UNIT) seterr(AL_INVALID_ENUM);
    UNLOCK();
}
AL_API void alListener3f(ALenum p, ALfloat x, ALfloat y, ALfloat z) {
    LOCK();
    ALCcontext *c = ctx();
    if (c && p == AL_POSITION) { c->lx = x; c->ly = y; c->lz = z; }
    else if (c && p != AL_VELOCITY) seterr(AL_INVALID_ENUM);
    UNLOCK();
}
AL_API void alListenerfv(ALenum p, const ALfloat *v) {
    if (!v) return;
    LOCK();
    ALCcontext *c = ctx();
    if (c && p == AL_ORIENTATION) {
        c->atx = v[0]; c->aty = v[1]; c->atz = v[2]; c->upx = v[3]; c->upy = v[4]; c->upz = v[5];
    } else if (p == AL_GAIN) alListenerf(p, v[0]);
    else alListener3f(p, v[0], v[1], v[2]);
    UNLOCK();
}
AL_API void alListeneri(ALenum p, ALint v) { alListenerf(p, (ALfloat)v); }
AL_API void alListener3i(ALenum p, ALint x, ALint y, ALint z) { alListener3f(p, x, y, z); }
AL_API void alListeneriv(ALenum p, const ALint *v) {
    if (!v) return;
    if (p == AL_ORIENTATION) { ALfloat f[6] = {v[0], v[1], v[2], v[3], v[4], v[5]}; alListenerfv(p, f); }
    else alListener3f(p, v[0], v[1], v[2]);
}
AL_API void alGetListenerf(ALenum p, ALfloat *v) { ALCcontext *c = ctx(); if (v && c) *v = p == AL_GAIN ? c->lgain : 0; }
AL_API void alGetListener3f(ALenum p, ALfloat *x, ALfloat *y, ALfloat *z) {
    ALCcontext *c = ctx();
    if (!c || !x || !y || !z) return;
    if (p == AL_POSITION) { *x = c->lx; *y = c->ly; *z = c->lz; } else { *x = *y = *z = 0; }
}
AL_API void alGetListenerfv(ALenum p, ALfloat *v) {
    ALCcontext *c = ctx();
    if (!c || !v) return;
    if (p == AL_ORIENTATION) { v[0] = c->atx; v[1] = c->aty; v[2] = c->atz; v[3] = c->upx; v[4] = c->upy; v[5] = c->upz; }
    else if (p == AL_GAIN) v[0] = c->lgain;
    else alGetListener3f(p, v, v + 1, v + 2);
}
AL_API void alGetListeneri(ALenum p, ALint *v) { ALfloat f = 0; alGetListenerf(p, &f); if (v) *v = (ALint)f; }
AL_API void alGetListener3i(ALenum p, ALint *x, ALint *y, ALint *z) {
    ALfloat a, b, cc; alGetListener3f(p, &a, &b, &cc); if (x && y && z) { *x = a; *y = b; *z = cc; }
}
AL_API void alGetListeneriv(ALenum p, ALint *v) {
    ALfloat f[6] = {0}; alGetListenerfv(p, f); if (v) for (int i = 0; i < (p == AL_ORIENTATION ? 6 : 3); i++) v[i] = f[i];
}

/* ---------------------------------------------------------------- buffers */

AL_API void alGenBuffers(ALsizei n, ALuint *out) {
    LOCK();
    for (int i = 0; i < n; i++) { MCBuffer *b = [MCBuffer new]; b.name = nextName++; buffers[@(b.name)] = b; out[i] = b.name; }
    UNLOCK();
}
AL_API void alDeleteBuffers(ALsizei n, const ALuint *names) {
    LOCK();
    for (int i = 0; i < n; i++) if (names[i]) [buffers removeObjectForKey:@(names[i])];
    UNLOCK();
}
AL_API ALboolean alIsBuffer(ALuint name) { LOCK(); BOOL r = name == 0 || buffers[@(name)] != nil; UNLOCK(); return r; }

AL_API void alBufferData(ALuint name, ALenum format, const ALvoid *data, ALsizei size, ALsizei freq) {
    LOCK();
    MCBuffer *b = buffers[@(name)];
    if (!b || freq <= 0 || size < 0) { seterr(b ? AL_INVALID_VALUE : AL_INVALID_NAME); UNLOCK(); return; }
    int ch, bits;
    switch (format) {
    case AL_FORMAT_MONO8: ch = 1; bits = 8; break;
    case AL_FORMAT_MONO16: ch = 1; bits = 16; break;
    case AL_FORMAT_STEREO8: ch = 2; bits = 8; break;
    case AL_FORMAT_STEREO16: ch = 2; bits = 16; break;
    case AL_FORMAT_MONO_FLOAT32: ch = 1; bits = 32; break;
    case AL_FORMAT_STEREO_FLOAT32: ch = 2; bits = 32; break;
    default: seterr(AL_INVALID_ENUM); UNLOCK(); return;
    }
    AVAudioFrameCount frames = (AVAudioFrameCount)(size / (ch * bits / 8));
    AVAudioFormat *f = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:freq channels:ch];
    AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:f frameCapacity:MAX(frames, 1)];
    pcm.frameLength = frames;
    for (int c = 0; c < ch; c++) {
        float *o = pcm.floatChannelData[c];
        if (bits == 8) { const unsigned char *s = data; for (AVAudioFrameCount i = 0; i < frames; i++) o[i] = (s[i * ch + c] - 128) / 128.0f; }
        else if (bits == 16) { const short *s = data; for (AVAudioFrameCount i = 0; i < frames; i++) o[i] = s[i * ch + c] / 32768.0f; }
        else { const float *s = data; for (AVAudioFrameCount i = 0; i < frames; i++) o[i] = s[i * ch + c]; }
    }
    b.pcm = pcm; b.freq = freq; b.bits = bits; b.channels = ch; b.size = size;
    UNLOCK();
}
AL_API void alBufferf(ALuint b, ALenum p, ALfloat v) {}
AL_API void alBuffer3f(ALuint b, ALenum p, ALfloat x, ALfloat y, ALfloat z) {}
AL_API void alBufferfv(ALuint b, ALenum p, const ALfloat *v) {}
AL_API void alBufferi(ALuint b, ALenum p, ALint v) {}
AL_API void alBuffer3i(ALuint b, ALenum p, ALint x, ALint y, ALint z) {}
AL_API void alBufferiv(ALuint b, ALenum p, const ALint *v) {}
AL_API void alGetBufferi(ALuint name, ALenum p, ALint *v) {
    if (!v) return;
    LOCK();
    MCBuffer *b = buffers[@(name)];
    if (!b) seterr(AL_INVALID_NAME);
    else switch (p) {
    case AL_FREQUENCY: *v = b.freq; break;
    case AL_BITS: *v = b.bits; break;
    case AL_CHANNELS: *v = b.channels; break;
    case AL_SIZE: *v = b.size; break;
    default: seterr(AL_INVALID_ENUM);
    }
    UNLOCK();
}
AL_API void alGetBufferiv(ALuint b, ALenum p, ALint *v) { alGetBufferi(b, p, v); }
AL_API void alGetBuffer3i(ALuint b, ALenum p, ALint *x, ALint *y, ALint *z) { seterr(AL_INVALID_ENUM); }
AL_API void alGetBufferf(ALuint b, ALenum p, ALfloat *v) { ALint i = 0; alGetBufferi(b, p, &i); if (v) *v = i; }
AL_API void alGetBufferfv(ALuint b, ALenum p, ALfloat *v) { alGetBufferf(b, p, v); }
AL_API void alGetBuffer3f(ALuint b, ALenum p, ALfloat *x, ALfloat *y, ALfloat *z) { seterr(AL_INVALID_ENUM); }

/* ---------------------------------------------------------------- sources: playback */

/* Make sure the source has a node connected for `fmt`, into the environment (mono, positional) or the plain
 * mixer. The node must be stopped. */
static void wire(MCSource *s, AVAudioFormat *fmt) {
    MCDevice *d = s.dev;
    BOOL env = fmt.channelCount == 1 && !(s.relative && s.px == 0 && s.py == 0 && s.pz == 0);
    if (s.node && s.toEnv == env && [s.nodeFormat isEqual:fmt]) return;
    if (!s.node) {
        s.node = [AVAudioPlayerNode new];
        [d.engine attachNode:s.node];
    } else [d.engine disconnectNodeOutput:s.node];
    [d.engine connect:s.node to:(env ? (AVAudioNode *)d.env : (AVAudioNode *)d.flat) format:fmt];
    s.nodeFormat = fmt;
    s.toEnv = env;
    if (env) {
        if (@available(macOS 13.0, *)) s.node.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmAuto;
        else s.node.renderingAlgorithm = AVAudio3DMixingRenderingAlgorithmHRTFHQ;
    }
}

static void finished(MCSource *s, unsigned gen, BOOL streamed) {
    dispatch_async(q, ^{
        LOCK();
        if (s.gen == gen && s.state == AL_PLAYING) {
            if (streamed) {
                s.processed = MIN(s.processed + 1, (ALint)s.queue.count);
                if (s.processed >= (ALint)s.queue.count) s.state = AL_STOPPED; /* ran dry */
            } else s.state = AL_STOPPED;
        }
        UNLOCK();
    });
}

/* Hand the queued buffers that aren't on the node yet to it. */
static void feed(MCSource *s) {
    unsigned gen = s.gen;
    while (s.scheduled < (ALint)s.queue.count) {
        MCBuffer *b = buffers[s.queue[s.scheduled]];
        s.scheduled++;
        if (!b.pcm) { finished(s, gen, YES); continue; }
        if (![b.pcm.format isEqual:s.nodeFormat]) { finished(s, gen, YES); continue; } /* format change mid-stream: skip */
        [s.node scheduleBuffer:b.pcm atTime:nil options:0 completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
              completionHandler:^(AVAudioPlayerNodeCompletionCallbackType t) { finished(s, gen, YES); }];
    }
}

static void playNow(MCSource *s, BOOL keepProcessed) {
    MCDevice *d = s.dev;
    if (!d) return;
    if (s.node) [s.node stop];
    s.gen++;
    unsigned gen = s.gen;
    MCBuffer *b = s.buffer ? buffers[@(s.buffer)] : nil;
    if (!keepProcessed) s.processed = 0; /* playing a stopped source starts its whole queue again, as in OpenAL */
    if (s.queue.count && s.processed >= (ALint)s.queue.count) { s.state = AL_STOPPED; return; }
    if (s.queue.count) {
        MCBuffer *first = buffers[s.queue[MIN((NSUInteger)s.processed, s.queue.count - 1)]];
        if (!first.pcm) { s.state = AL_STOPPED; return; }
        wire(s, first.pcm.format);
        s.scheduled = s.processed;
        s.state = AL_PLAYING;
        feed(s);
    } else if (b.pcm) {
        wire(s, b.pcm.format);
        s.state = AL_PLAYING;
        [s.node scheduleBuffer:b.pcm atTime:nil options:(s.looping ? AVAudioPlayerNodeBufferLoops : 0)
              completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
              completionHandler:^(AVAudioPlayerNodeCompletionCallbackType t) { finished(s, gen, NO); }];
    } else {
        s.state = AL_STOPPED;
        return;
    }
    apply(s);
    if (!d.running) startEngine(d);
    if (d.running) [s.node play];
    if (verbose()) lg("source %u plays %s (%s)", s.name, s.queue.count ? "a stream" : "a buffer", s.toEnv ? "3D" : "flat");
}

/* after an engine restart (lock held): streams carry on from the buffer they were on */
static void restart(MCSource *s) { playNow(s, YES); }

static MCSource *src(ALuint name) {
    MCSource *s = sources[@(name)];
    if (!s) seterr(AL_INVALID_NAME);
    return s;
}

AL_API void alGenSources(ALsizei n, ALuint *out) {
    LOCK();
    ALCcontext *c = ctx();
    if (!c) { seterr(AL_INVALID_OPERATION); UNLOCK(); return; }
    for (int i = 0; i < n; i++) {
        MCSource *s = [MCSource new];
        s.name = nextName++;
        s.dev = devOf(c);
        s.ctx = c;
        sources[@(s.name)] = s;
        out[i] = s.name;
    }
    UNLOCK();
}
AL_API void alDeleteSources(ALsizei n, const ALuint *names) {
    LOCK();
    for (int i = 0; i < n; i++) {
        MCSource *s = sources[@(names[i])];
        if (!s) continue;
        s.gen++;
        if (s.node) { [s.node stop]; [s.dev.engine detachNode:s.node]; }
        [sources removeObjectForKey:@(names[i])];
    }
    UNLOCK();
}
AL_API ALboolean alIsSource(ALuint name) { LOCK(); BOOL r = sources[@(name)] != nil; UNLOCK(); return r; }

AL_API void alSourcePlay(ALuint name) { LOCK(); MCSource *s = src(name); if (s) { if (s.state == AL_PAUSED && s.node) { s.state = AL_PLAYING; [s.node play]; } else playNow(s, NO); } UNLOCK(); }
AL_API void alSourcePause(ALuint name) { LOCK(); MCSource *s = src(name); if (s && s.state == AL_PLAYING) { s.state = AL_PAUSED; [s.node pause]; } UNLOCK(); }
AL_API void alSourceStop(ALuint name) {
    LOCK();
    MCSource *s = src(name);
    if (s) {
        s.gen++;
        if (s.node) [s.node stop];
        s.state = AL_STOPPED;
        s.processed = (ALint)s.queue.count; /* stopping marks every queued buffer processed */
        s.scheduled = s.processed;
    }
    UNLOCK();
}
AL_API void alSourceRewind(ALuint name) {
    LOCK();
    MCSource *s = src(name);
    if (s) { s.gen++; if (s.node) [s.node stop]; s.state = AL_INITIAL; s.processed = 0; s.scheduled = 0; }
    UNLOCK();
}
AL_API void alSourcePlayv(ALsizei n, const ALuint *v) { for (int i = 0; i < n; i++) alSourcePlay(v[i]); }
AL_API void alSourcePausev(ALsizei n, const ALuint *v) { for (int i = 0; i < n; i++) alSourcePause(v[i]); }
AL_API void alSourceStopv(ALsizei n, const ALuint *v) { for (int i = 0; i < n; i++) alSourceStop(v[i]); }
AL_API void alSourceRewindv(ALsizei n, const ALuint *v) { for (int i = 0; i < n; i++) alSourceRewind(v[i]); }

AL_API void alSourceQueueBuffers(ALuint name, ALsizei n, const ALuint *bufs) {
    LOCK();
    MCSource *s = src(name);
    if (s) {
        if (s.buffer) { seterr(AL_INVALID_OPERATION); UNLOCK(); return; }
        for (int i = 0; i < n; i++) [s.queue addObject:@(bufs[i])];
        if (s.state == AL_PLAYING && s.node) feed(s);
    }
    UNLOCK();
}
AL_API void alSourceUnqueueBuffers(ALuint name, ALsizei n, ALuint *bufs) {
    LOCK();
    MCSource *s = src(name);
    if (s) {
        if (n > s.processed) { seterr(AL_INVALID_VALUE); UNLOCK(); return; }
        for (int i = 0; i < n; i++) { bufs[i] = s.queue[0].unsignedIntValue; [s.queue removeObjectAtIndex:0]; }
        s.processed -= n;
        s.scheduled = MAX(0, s.scheduled - n);
    }
    UNLOCK();
}

/* ---------------------------------------------------------------- sources: properties */

static FilterParams filterParams(ALuint name) {
    MCFilter *f = filters[@(name)];
    FilterParams p = {1, 1, AL_FILTER_NULL};
    if (f) { p.gain = f.gain; p.gainHF = f.gainHF; p.type = f.type; }
    return p;
}

AL_API void alSourcef(ALuint name, ALenum p, ALfloat v) {
    LOCK();
    MCSource *s = src(name);
    if (s) switch (p) {
    case AL_GAIN: s.gain = v; break;
    case AL_PITCH: s.pitch = v; break;
    case AL_MIN_GAIN: s.minGain = v; break;
    case AL_MAX_GAIN: s.maxGain = v; break;
    case AL_REFERENCE_DISTANCE: s.refDist = v; break;
    case AL_ROLLOFF_FACTOR: s.rolloff = v; break;
    case AL_MAX_DISTANCE: s.maxDist = v; break;
    case AL_AIR_ABSORPTION_FACTOR: s.airAbsorption = v; break;
    case AL_CONE_INNER_ANGLE: case AL_CONE_OUTER_ANGLE: case AL_CONE_OUTER_GAIN: case AL_CONE_OUTER_GAINHF:
    case AL_ROOM_ROLLOFF_FACTOR: case AL_DOPPLER_FACTOR: break;
    case AL_SEC_OFFSET: case AL_SAMPLE_OFFSET: case AL_BYTE_OFFSET: break; /* seeking: not needed by the game */
    default: seterr(AL_INVALID_ENUM);
    }
    if (s && s.state == AL_PLAYING) apply(s);
    UNLOCK();
}
AL_API void alSource3f(ALuint name, ALenum p, ALfloat x, ALfloat y, ALfloat z) {
    LOCK();
    MCSource *s = src(name);
    if (s) {
        if (p == AL_POSITION) { s.px = x; s.py = y; s.pz = z; if (s.state == AL_PLAYING) apply(s); }
        else if (p != AL_VELOCITY && p != AL_DIRECTION) seterr(AL_INVALID_ENUM);
    }
    UNLOCK();
}
AL_API void alSourcefv(ALuint name, ALenum p, const ALfloat *v) {
    if (!v) return;
    if (p == AL_POSITION || p == AL_VELOCITY || p == AL_DIRECTION) alSource3f(name, p, v[0], v[1], v[2]);
    else alSourcef(name, p, v[0]);
}
AL_API void alSourcei(ALuint name, ALenum p, ALint v) {
    LOCK();
    MCSource *s = src(name);
    if (s) switch (p) {
    case AL_SOURCE_RELATIVE: s.relative = v; break;
    case AL_LOOPING: s.looping = v; break;
    case AL_DISTANCE_MODEL: s.model = v; break;
    case AL_BUFFER:
        if (s.state == AL_PLAYING || s.state == AL_PAUSED) { seterr(AL_INVALID_OPERATION); break; }
        if (v && !buffers[@(v)]) { seterr(AL_INVALID_VALUE); break; }
        s.buffer = v;
        [s.queue removeAllObjects];
        s.processed = 0;
        s.scheduled = 0;
        break;
    case AL_DIRECT_FILTER: s.direct = filterParams(v); break;
    case AL_DIRECT_FILTER_GAINHF_AUTO: case AL_AUXILIARY_SEND_FILTER_GAIN_AUTO: case AL_AUXILIARY_SEND_FILTER_GAINHF_AUTO: break;
    case AL_REFERENCE_DISTANCE: case AL_ROLLOFF_FACTOR: case AL_MAX_DISTANCE: case AL_GAIN: case AL_PITCH:
        UNLOCK(); alSourcef(name, p, (ALfloat)v); return;
    case AL_SEC_OFFSET: case AL_SAMPLE_OFFSET: case AL_BYTE_OFFSET: break;
    default: seterr(AL_INVALID_ENUM);
    }
    if (s && s.state == AL_PLAYING) apply(s);
    UNLOCK();
}
AL_API void alSource3i(ALuint name, ALenum p, ALint a, ALint b, ALint c) {
    LOCK();
    MCSource *s = src(name);
    if (s) {
        if (p == AL_AUXILIARY_SEND_FILTER) {
            FilterParams f = filterParams(c);
            ALuint slot = (ALuint)a;
            switch (b) {
            case 0: s.sendSlot0 = slot; s.send0 = f; break;
            case 1: s.sendSlot1 = slot; s.send1 = f; break;
            case 2: s.sendSlot2 = slot; s.send2 = f; break;
            case 3: s.sendSlot3 = slot; s.send3 = f; break;
            default: seterr(AL_INVALID_VALUE);
            }
            if (s.state == AL_PLAYING) apply(s);
        } else { UNLOCK(); alSource3f(name, p, a, b, c); return; }
    }
    UNLOCK();
}
AL_API void alSourceiv(ALuint name, ALenum p, const ALint *v) {
    if (!v) return;
    if (p == AL_AUXILIARY_SEND_FILTER || p == AL_POSITION || p == AL_VELOCITY || p == AL_DIRECTION) alSource3i(name, p, v[0], v[1], v[2]);
    else alSourcei(name, p, v[0]);
}

static double offsetFrames(MCSource *s) {
    if (!s.node || s.state != AL_PLAYING) return 0;
    AVAudioTime *t = s.node.lastRenderTime;
    if (!t) return 0;
    AVAudioTime *pt = [s.node playerTimeForNodeTime:t];
    return pt ? (double)pt.sampleTime : 0;
}

AL_API void alGetSourcef(ALuint name, ALenum p, ALfloat *v);

AL_API void alGetSourcei(ALuint name, ALenum p, ALint *v) {
    if (!v) return;
    LOCK();
    MCSource *s = src(name);
    if (s) switch (p) {
    case AL_SOURCE_STATE: *v = s.state; break;
    case AL_BUFFERS_QUEUED: *v = (ALint)s.queue.count; break;
    case AL_BUFFERS_PROCESSED: *v = s.state == AL_INITIAL ? 0 : s.processed; break;
    case AL_BUFFER: *v = (ALint)s.buffer; break;
    case AL_LOOPING: *v = s.looping; break;
    case AL_SOURCE_RELATIVE: *v = s.relative; break;
    case AL_DISTANCE_MODEL: *v = s.model; break;
    case AL_SOURCE_TYPE: *v = s.buffer ? AL_STATIC : s.queue.count ? AL_STREAMING : AL_UNDETERMINED; break;
    case AL_SAMPLE_OFFSET: *v = (ALint)offsetFrames(s); break;
    case AL_SEC_OFFSET: *v = s.nodeFormat ? (ALint)(offsetFrames(s) / s.nodeFormat.sampleRate) : 0; break;
    case AL_BYTE_OFFSET: *v = (ALint)offsetFrames(s) * 2 * (s.nodeFormat ? (ALint)s.nodeFormat.channelCount : 1); break;
    default: { UNLOCK(); ALfloat f = 0; alGetSourcef(name, p, &f); *v = (ALint)f; return; }
    }
    UNLOCK();
}
AL_API void alGetSourcef(ALuint name, ALenum p, ALfloat *v) {
    if (!v) return;
    LOCK();
    MCSource *s = src(name);
    if (s) switch (p) {
    case AL_GAIN: *v = s.gain; break;
    case AL_PITCH: *v = s.pitch; break;
    case AL_MIN_GAIN: *v = s.minGain; break;
    case AL_MAX_GAIN: *v = s.maxGain; break;
    case AL_REFERENCE_DISTANCE: *v = s.refDist; break;
    case AL_ROLLOFF_FACTOR: *v = s.rolloff; break;
    case AL_MAX_DISTANCE: *v = s.maxDist; break;
    case AL_AIR_ABSORPTION_FACTOR: *v = s.airAbsorption; break;
    case AL_SEC_OFFSET: *v = s.nodeFormat ? (ALfloat)(offsetFrames(s) / s.nodeFormat.sampleRate) : 0; break;
    case AL_SAMPLE_OFFSET: *v = (ALfloat)offsetFrames(s); break;
    case AL_CONE_INNER_ANGLE: case AL_CONE_OUTER_ANGLE: *v = 360; break;
    case AL_CONE_OUTER_GAIN: *v = 0; break;
    default: seterr(AL_INVALID_ENUM);
    }
    UNLOCK();
}
AL_API void alGetSource3f(ALuint name, ALenum p, ALfloat *x, ALfloat *y, ALfloat *z) {
    if (!x || !y || !z) return;
    LOCK();
    MCSource *s = src(name);
    if (s) { if (p == AL_POSITION) { *x = s.px; *y = s.py; *z = s.pz; } else { *x = *y = *z = 0; } }
    UNLOCK();
}
AL_API void alGetSourcefv(ALuint name, ALenum p, ALfloat *v) {
    if (!v) return;
    if (p == AL_POSITION || p == AL_VELOCITY || p == AL_DIRECTION) alGetSource3f(name, p, v, v + 1, v + 2);
    else alGetSourcef(name, p, v);
}
AL_API void alGetSource3i(ALuint name, ALenum p, ALint *x, ALint *y, ALint *z) {
    ALfloat a = 0, b = 0, c = 0; alGetSource3f(name, p, &a, &b, &c); if (x && y && z) { *x = a; *y = b; *z = c; }
}
AL_API void alGetSourceiv(ALuint name, ALenum p, ALint *v) {
    if (!v) return;
    if (p == AL_POSITION || p == AL_VELOCITY || p == AL_DIRECTION) alGetSource3i(name, p, v, v + 1, v + 2);
    else alGetSourcei(name, p, v);
}

/* ---------------------------------------------------------------- EFX objects */

#define GEN(fn, Cls, table) \
    AL_API void fn(ALsizei n, ALuint *out) { LOCK(); for (int i = 0; i < n; i++) { Cls *o = [Cls new]; o.name = nextName++; table[@(o.name)] = o; out[i] = o.name; } UNLOCK(); }
#define DEL(fn, table) \
    AL_API void fn(ALsizei n, const ALuint *names) { LOCK(); for (int i = 0; i < n; i++) if (names[i]) [table removeObjectForKey:@(names[i])]; UNLOCK(); }
#define IS(fn, table) \
    AL_API ALboolean fn(ALuint name) { LOCK(); BOOL r = name == 0 || table[@(name)] != nil; UNLOCK(); return r; }

GEN(alGenFilters, MCFilter, filters) DEL(alDeleteFilters, filters) IS(alIsFilter, filters)
GEN(alGenEffects, MCEffect, effects) DEL(alDeleteEffects, effects) IS(alIsEffect, effects)
GEN(alGenAuxiliaryEffectSlots, MCSlot, slots) DEL(alDeleteAuxiliaryEffectSlots, slots) IS(alIsAuxiliaryEffectSlot, slots)

AL_API void alFilteri(ALuint name, ALenum p, ALint v) {
    LOCK();
    MCFilter *f = filters[@(name)];
    if (!f) seterr(AL_INVALID_NAME);
    else if (p == AL_FILTER_TYPE) f.type = v;
    else seterr(AL_INVALID_ENUM);
    UNLOCK();
}
AL_API void alFilterf(ALuint name, ALenum p, ALfloat v) {
    LOCK();
    MCFilter *f = filters[@(name)];
    if (!f) seterr(AL_INVALID_NAME);
    else if (p == AL_LOWPASS_GAIN) f.gain = v;
    else if (p == AL_LOWPASS_GAINHF) f.gainHF = v;
    UNLOCK();
}
AL_API void alFilteriv(ALuint f, ALenum p, const ALint *v) { if (v) alFilteri(f, p, v[0]); }
AL_API void alFilterfv(ALuint f, ALenum p, const ALfloat *v) { if (v) alFilterf(f, p, v[0]); }
AL_API void alGetFilteri(ALuint name, ALenum p, ALint *v) { LOCK(); MCFilter *f = filters[@(name)]; if (f && v && p == AL_FILTER_TYPE) *v = f.type; UNLOCK(); }
AL_API void alGetFilteriv(ALuint f, ALenum p, ALint *v) { alGetFilteri(f, p, v); }
AL_API void alGetFilterf(ALuint name, ALenum p, ALfloat *v) {
    LOCK(); MCFilter *f = filters[@(name)]; if (f && v) *v = p == AL_LOWPASS_GAINHF ? f.gainHF : f.gain; UNLOCK();
}
AL_API void alGetFilterfv(ALuint f, ALenum p, ALfloat *v) { alGetFilterf(f, p, v); }

AL_API void alEffecti(ALuint name, ALenum p, ALint v) {
    LOCK();
    MCEffect *e = effects[@(name)];
    if (!e) seterr(AL_INVALID_NAME);
    else if (p == AL_EFFECT_TYPE) e.type = v;
    UNLOCK();
}
AL_API void alEffectf(ALuint name, ALenum p, ALfloat v) {
    LOCK();
    MCEffect *e = effects[@(name)];
    if (!e) seterr(AL_INVALID_NAME);
    else if ((e.type == AL_EFFECT_EAXREVERB && p == AL_EAXREVERB_DECAY_TIME) || (e.type == AL_EFFECT_REVERB && p == AL_REVERB_DECAY_TIME)) e.decay = v;
    else if (p == AL_REVERB_GAIN) e.gain = v; /* the same number for both reverbs */
    UNLOCK();
}
AL_API void alEffectiv(ALuint e, ALenum p, const ALint *v) { if (v) alEffecti(e, p, v[0]); }
AL_API void alEffectfv(ALuint e, ALenum p, const ALfloat *v) { if (v) alEffectf(e, p, v[0]); } /* vector params: not used */
AL_API void alGetEffecti(ALuint name, ALenum p, ALint *v) { LOCK(); MCEffect *e = effects[@(name)]; if (e && v && p == AL_EFFECT_TYPE) *v = e.type; UNLOCK(); }
AL_API void alGetEffectiv(ALuint e, ALenum p, ALint *v) { alGetEffecti(e, p, v); }
AL_API void alGetEffectf(ALuint name, ALenum p, ALfloat *v) { LOCK(); MCEffect *e = effects[@(name)]; if (e && v) *v = p == AL_REVERB_GAIN ? e.gain : e.decay; UNLOCK(); }
AL_API void alGetEffectfv(ALuint e, ALenum p, ALfloat *v) { alGetEffectf(e, p, v); }

/* Loading an effect into a slot copies its settings, as in OpenAL. */
AL_API void alAuxiliaryEffectSloti(ALuint name, ALenum p, ALint v) {
    LOCK();
    MCSlot *s = slots[@(name)];
    if (!s) seterr(AL_INVALID_NAME);
    else if (p == AL_EFFECTSLOT_EFFECT) {
        MCEffect *e = effects[@(v)];
        s.effect = v;
        s.effectType = e ? e.type : AL_EFFECT_NULL;
        s.effectGain = e ? e.gain : 0;
        s.decay = e ? e.decay : 0;
    }
    UNLOCK();
}
AL_API void alAuxiliaryEffectSlotf(ALuint name, ALenum p, ALfloat v) {
    LOCK(); MCSlot *s = slots[@(name)]; if (!s) seterr(AL_INVALID_NAME); else if (p == AL_EFFECTSLOT_GAIN) s.gain = v; UNLOCK();
}
AL_API void alAuxiliaryEffectSlotiv(ALuint s, ALenum p, const ALint *v) { if (v) alAuxiliaryEffectSloti(s, p, v[0]); }
AL_API void alAuxiliaryEffectSlotfv(ALuint s, ALenum p, const ALfloat *v) { if (v) alAuxiliaryEffectSlotf(s, p, v[0]); }
AL_API void alGetAuxiliaryEffectSloti(ALuint name, ALenum p, ALint *v) {
    LOCK(); MCSlot *s = slots[@(name)]; if (s && v) *v = p == AL_EFFECTSLOT_EFFECT ? (ALint)s.effect : 1; UNLOCK();
}
AL_API void alGetAuxiliaryEffectSlotiv(ALuint s, ALenum p, ALint *v) { alGetAuxiliaryEffectSloti(s, p, v); }
AL_API void alGetAuxiliaryEffectSlotf(ALuint name, ALenum p, ALfloat *v) { LOCK(); MCSlot *s = slots[@(name)]; if (s && v) *v = s.gain; UNLOCK(); }
AL_API void alGetAuxiliaryEffectSlotfv(ALuint s, ALenum p, ALfloat *v) { alGetAuxiliaryEffectSlotf(s, p, v); }
