package mcmetal.loader;

import java.lang.reflect.Method;

/**
 * MCMETAL_FPS_LOG=1: prints Minecraft's own frame counter ("[mcmetal] fps 143") every 5 seconds, whichever OpenGL
 * is in use, so Apple's OpenGL and mcmetal can be compared in the same scene. Reads Minecraft.getInstance().getFps()
 * through the render thread's class loader once the game has started; never touches the game otherwise.
 */
final class FpsLog {
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
            while (true) {
                Thread.sleep(5000);
                Object mc = getInstance.invoke(null);
                if (mc != null)
                    MetalBootstrap.log("fps " + getFps.invoke(mc));
            }
        } catch (Throwable t) {
            MetalBootstrap.log("fps log stopped: " + t);
        }
    }
}
