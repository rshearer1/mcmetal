package mcmetal.loader.audio;

import java.util.concurrent.LinkedBlockingQueue;

import com.sonicether.soundphysics.SoundPhysics;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.sounds.SoundSource;
import org.lwjgl.openal.AL11;
import org.lwjgl.openal.EXTEfx;

/**
 * Sound Physics Remastered's ray tracing on its own thread, Java side (on unless MCMETAL_SOUND_PHYSICS_ASYNC=0; see
 * SoundPhysicsTransformer).
 *
 * Not used as a class: SoundPhysicsTransformer copies these static fields and methods into
 * com.sonicether.soundphysics.SoundPhysics (names prefixed "mcmetal$"), makes SoundPhysics a Runnable whose run()
 * calls loop(), points onPlaySound(x, y, z, source) at play() and has setEnvironment(source, ...) call applied(source)
 * first.
 * Sound Physics traces its rays (32 rays x 4 bounces plus occlusion, 1-4 ms per sound in a Linux test) inside
 * Channel.play() on Minecraft's sound engine thread. The render thread waits for that thread on every new sound
 * (SoundEngine.play joins createHandle()), so when several sounds start in one tick it sat behind all their rays:
 * 1.4 s of render-thread waiting a minute with ten sounds a second, up to 20 ms at once (Linux test, 10-23). Now the
 * sound engine thread only hands the sound to one daemon thread here and moves on. Until its rays are done the
 * sound is held silent (a zero-gain direct filter, no reverb sends), so it never plays without its echo and
 * muffling; Sound Physics' setEnvironment() then replaces the hold, a few milliseconds later.
 * No static initializer, lambdas or nested classes (they would not be copied), so every field starts at its
 * default value: no thread, no queue, no hold filter.
 */
public final class SoundPhysicsHooks {
    private static LinkedBlockingQueue<Object[]> queue; // sounds waiting for their rays: {source, x, y, z, category, sound}
    private static Thread worker;
    private static int holdFilter;                      // zero-gain low-pass filter that keeps a sound silent
    private static boolean noHold;                      // the hold failed once (no EFX?): play sounds dry until traced
    private static volatile int applied;                // the source setEnvironment() last ran for on the worker
    private static boolean failed;                      // the worker could not start: trace on the calling thread
    private static boolean told;                        // the first traced sound was logged

    private SoundPhysicsHooks() {
    }

    /** Stands in for SoundPhysics.onPlaySound(x, y, z, source): at the start of Channel.play(), sound engine thread. */
    public static void play(double x, double y, double z, int source) {
        SoundSource category = SoundPhysics.lastSoundCategory; // what onPlaySound() itself reads, read at the same moment
        ResourceLocation sound = SoundPhysics.lastSound;
        LinkedBlockingQueue<Object[]> q = queue;
        if (q == null && !failed)
            q = start();
        if (q == null) {
            SoundPhysics.processSound(source, x, y, z, category, sound, false);
            return;
        }
        if (q.size() < 32) // a long queue (a huge burst of sounds): the rest play dry for a moment rather than late
            hold(source);
        q.add(new Object[] {source, x, y, z, category, sound});
    }

    private static LinkedBlockingQueue<Object[]> start() {
        synchronized (SoundPhysicsHooks.class) {
            if (queue == null && !failed) {
                try {
                    LinkedBlockingQueue<Object[]> q = new LinkedBlockingQueue<>();
                    Thread t = new Thread((Runnable) (Object) new SoundPhysics(), "mcmetal sound physics");
                    t.setDaemon(true);
                    worker = t;
                    queue = q; // before start(): loop() takes from it
                    t.start();
                } catch (Throwable e) {
                    queue = null;
                    failed = true;
                    System.out.println("[mcmetal] sound physics: could not start its thread, tracing stays on the sound engine thread: " + e);
                }
            }
            return queue;
        }
    }

    /** Silences a source until its environment is set: dry path through a zero-gain filter, reverb sends off. */
    private static void hold(int source) {
        if (noHold)
            return;
        try {
            int f = holdFilter;
            if (f == 0 || !EXTEfx.alIsFilter(f)) { // first sound, or the sound engine made a new OpenAL context
                f = EXTEfx.alGenFilters();
                EXTEfx.alFilteri(f, EXTEfx.AL_FILTER_TYPE, EXTEfx.AL_FILTER_LOWPASS);
                EXTEfx.alFilterf(f, EXTEfx.AL_LOWPASS_GAIN, 0f);
                holdFilter = f;
            }
            AL11.alSourcei(source, EXTEfx.AL_DIRECT_FILTER, f);
            for (int i = 0; i < Math.min(SoundPhysics.maxAuxSends, 4); i++)
                AL11.alSource3i(source, EXTEfx.AL_AUXILIARY_SEND_FILTER, EXTEfx.AL_EFFECTSLOT_NULL, i, EXTEfx.AL_FILTER_NULL);
        } catch (Throwable e) {
            noHold = true;
            System.out.println("[mcmetal] sound physics: can't hold sounds until they're traced, they start dry: " + e);
        }
    }

    /** SoundPhysics.run(), on the worker: traces each sound in the order they started. */
    public static void loop() {
        LinkedBlockingQueue<Object[]> q = queue;
        for (;;) {
            Object[] j;
            try {
                j = q.take();
            } catch (InterruptedException e) {
                return;
            }
            int source = (Integer) j[0];
            if (!live(source)) // a short sound that already finished (Minecraft deleted its source): nothing to trace,
                continue;      // and tracing it made Sound Physics log an AL_INVALID_NAME error per sound
            applied = -1;
            long t0 = System.nanoTime();
            try {
                SoundPhysics.processSound(source, (Double) j[1], (Double) j[2], (Double) j[3], (SoundSource) j[4], (ResourceLocation) j[5], false);
            } catch (Throwable e) {
                // as when Sound Physics fails on the sound engine thread: this sound keeps vanilla's sound
            }
            if (!told) {
                told = true;
                System.out.println("[mcmetal] sound physics: first sound traced on its own thread in "
                        + (System.nanoTime() - t0) / 1000 + " us" + (applied == source ? "" : " (no environment set)"));
            }
            if (applied != source && !noHold) { // Sound Physics turned off, or it failed: let the sound play as vanilla
                try {
                    AL11.alSourcei(source, EXTEfx.AL_DIRECT_FILTER, EXTEfx.AL_FILTER_NULL);
                } catch (Throwable e) {
                    // the sound engine is shutting down
                }
            }
        }
    }

    /** Whether a queued sound's source still exists and hasn't finished playing. */
    private static boolean live(int source) {
        try {
            return AL11.alIsSource(source) && AL11.alGetSourcei(source, AL11.AL_SOURCE_STATE) != AL11.AL_STOPPED;
        } catch (Throwable e) {
            return false; // the sound engine is shutting down
        }
    }

    /** First thing in SoundPhysics.setEnvironment(source, ...), any thread. */
    public static void applied(int source) {
        if (Thread.currentThread() == worker)
            applied = source;
    }
}
