package mcmetal.loader.audio;

import org.lwjgl.openal.ALC10;

/**
 * The audio-device check off the render thread, Java side (on unless MCMETAL_AUDIO_ASYNC=0; see AudioTransformer).
 *
 * Not used as a class: AudioTransformer copies these static fields and methods into Minecraft's
 * com.mojang.blaze3d.audio.Library (names prefixed "mcmetal$"), makes Library a Runnable whose run() calls check(),
 * and in isCurrentDeviceDisconnected() swaps the OpenAL call alcGetInteger(device, ALC_CONNECTED) for
 * connected(device, ALC_CONNECTED, this); the rest of that method (it only asks when the device supports
 * ALC_EXT_disconnect) stays as it is.
 * The sound engine asks that every tick on the render thread; with Simple Voice Chat's OpenAL devices open the
 * answer (alcGetIntegerv ALC_CONNECTED) sometimes took 20-30 s, freezing the game (M3 run J2). Now one daemon thread
 * at a time asks OpenAL and the render thread gets the last answer straight away, so a lost device is noticed up to
 * a quarter of a second later and a slow answer never holds up a frame. No static initializer, lambdas or nested classes (they
 * would not be copied), so every field starts at its default value: "connected", nothing in flight.
 */
public final class AudioHooks {
    private static volatile boolean busy;  // a check thread is running
    private static volatile boolean lost;  // its last answer: the device is gone
    private static volatile long device;   // the device it checks
    private static volatile int param;     // what it asks (ALC_CONNECTED)
    private static volatile long slowMs;   // slowest answer so far, for the log
    private static long lastStart;         // when the last check started (render thread only), ns

    private AudioHooks() {
    }

    /** Stands in for ALC11.alcGetInteger(dev, what): start a check if none is running, answer with the last result. */
    public static int connected(long dev, int what, Object library) {
        if (dev != device) { // a new device (the sound engine reopened it): forget the old answer
            device = dev;
            lost = false;
        }
        param = what;
        long now = System.nanoTime();
        if (!busy && dev != 0 && (lastStart == 0 || now - lastStart >= 250_000_000L)) { // at most 4 checks a second, not one per tick
            busy = true;
            lastStart = now;
            Thread t = new Thread((Runnable) library, "mcmetal audio device check");
            t.setDaemon(true);
            t.start();
        }
        return lost ? 0 : 1;
    }

    /** Library.run(), on the check thread. */
    public static void check() {
        long dev = device, t0 = System.nanoTime();
        try {
            int v = ALC10.alcGetInteger(dev, param);
            if (dev == device)
                lost = v == 0;
        } catch (Throwable e) {
            // leave the last answer; the next tick tries again
        } finally {
            long ms = (System.nanoTime() - t0) / 1000000;
            if (ms > 1000 && ms > slowMs) {
                slowMs = ms;
                System.out.println("[mcmetal] audio device check took " + ms + " ms (off the render thread)");
            }
            busy = false;
        }
    }
}
