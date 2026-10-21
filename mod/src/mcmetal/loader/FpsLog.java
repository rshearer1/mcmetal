package mcmetal.loader;

import java.io.File;
import java.lang.reflect.Method;
import java.util.function.Consumer;

/**
 * MCMETAL_FPS_LOG=1: prints Minecraft's own frame counter ("[mcmetal] fps 143") every 5 seconds (MCMETAL_FPS_EVERY=n: every n seconds), whichever OpenGL
 * is in use, so Apple's OpenGL and mcmetal can be compared in the same scene. Reads Minecraft.getInstance().getFps()
 * through the render thread's class loader once the game has started; never touches the game otherwise.
 * On Apple's OpenGL (MCMETAL_DISABLE) the test rig's "shoot" file in MGL_SHOT_DIR makes Minecraft take its own
 * screenshot (MGL_SHOT_DIR/screenshots/apple-N.png), since mcmetal's screenshot code isn't running there.
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
            String shotDir = System.getenv("MCMETAL_DISABLE") != null ? System.getenv("MGL_SHOT_DIR") : null;
            int shots = 0;
            long next = System.currentTimeMillis();
            while (true) {
                Thread.sleep(shotDir != null ? 250 : EVERY_MS);
                Object mc = getInstance.invoke(null);
                if (mc == null)
                    continue;
                File shoot = shotDir != null ? new File(shotDir, "shoot") : null;
                if (shoot != null && shoot.exists() && shoot.delete())
                    screenshot(mc, new File(shotDir), "apple-" + (++shots) + ".png");
                if (System.currentTimeMillis() < next)
                    continue;
                next += EVERY_MS;
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

    /** Minecraft's own screenshot (F2), on the render thread. */
    private static void screenshot(Object mc, File dir, String name) {
        try {
            ClassLoader cl = mc.getClass().getClassLoader();
            Class<?> shot = Class.forName("net.minecraft.client.Screenshot", true, cl);
            Class<?> target = Class.forName("com.mojang.blaze3d.pipeline.RenderTarget", true, cl);
            Object fb = mc.getClass().getMethod("getMainRenderTarget").invoke(mc);
            Method grab = shot.getMethod("grab", File.class, String.class, target, Consumer.class);
            Consumer<Object> done = msg -> MetalBootstrap.log("screenshot " + name);
            Runnable r = () -> {
                try {
                    grab.invoke(null, dir, name, fb, done);
                } catch (ReflectiveOperationException e) {
                    MetalBootstrap.log("screenshot failed: " + e);
                }
            };
            mc.getClass().getMethod("execute", Runnable.class).invoke(mc, r);
        } catch (ReflectiveOperationException | RuntimeException e) {
            MetalBootstrap.log("screenshot failed: " + e);
        }
    }
}
