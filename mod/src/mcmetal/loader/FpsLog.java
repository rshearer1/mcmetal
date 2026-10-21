package mcmetal.loader;

import java.lang.reflect.Method;

/**
 * MCMETAL_FPS_LOG=1: prints Minecraft's own frame counter ("[mcmetal] fps 143") every 5 seconds (MCMETAL_FPS_EVERY=n: every n seconds), whichever OpenGL
 * is in use, so Apple's OpenGL and mcmetal can be compared in the same scene. Reads Minecraft.getInstance().getFps()
 * through the render thread's class loader once the game has started; never touches the game otherwise.
 */
final class FpsLog {
    private static final long EVERY_MS = everyMs();

    private static long everyMs() {
        try {
            return Math.max(1, Long.parseLong(System.getenv().getOrDefault("MCMETAL_FPS_EVERY", "5"))) * 1000;
        } catch (NumberFormatException e) {
            return 5000;
        }
    }

    private FpsLog() {
    }

    static void start() {
        Thread t = new Thread(FpsLog::run, "mcmetal fps log");
        t.setDaemon(true);
        t.start();
    }

    private static void run() {
        try {
            Method getInstance = null, getFps = null;
            while (getFps == null) {
                Thread.sleep(2000);
                for (Thread th : Thread.getAllStackTraces().keySet()) {
                    if (!th.getName().equals("Render thread") || th.getContextClassLoader() == null)
                        continue;
                    try {
                        Class<?> mc = Class.forName("net.minecraft.client.Minecraft", false, th.getContextClassLoader());
                        getInstance = mc.getMethod("getInstance");
                        getFps = mc.getMethod("getFps");
                    } catch (ReflectiveOperationException | LinkageError e) {
                        // game classes not loaded yet
                    }
                }
            }
            boolean f3 = System.getenv("MCMETAL_F3") != null;
            while (true) {
                Thread.sleep(EVERY_MS);
                Object mc = getInstance.invoke(null);
                if (mc == null)
                    continue;
                if (f3 && mc.getClass().getField("level").get(mc) != null)
                    f3 = !openDebugScreen(mc);
                MetalBootstrap.log("fps " + getFps.invoke(mc));
            }
        } catch (Throwable t) {
            MetalBootstrap.log("fps log stopped: " + t);
        }
    }

    /** MCMETAL_F3=1 (benchmarks): open the F3 debug screen once a world is loaded, as if the player pressed F3. */
    private static boolean openDebugScreen(Object mc) {
        try {
            Object gui = mc.getClass().getField("gui").get(mc);
            Object overlay = gui.getClass().getMethod("getDebugOverlay").invoke(gui);
            overlay.getClass().getMethod("toggleOverlay").invoke(overlay);
            MetalBootstrap.log("opened the F3 debug screen");
        } catch (ReflectiveOperationException | RuntimeException e) {
            MetalBootstrap.log("could not open the F3 debug screen: " + e);
        }
        return true;
    }
}
