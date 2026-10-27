package mcmetal.loader.load.jei;

import java.lang.invoke.MethodHandles;
import java.util.Base64;

import mezz.jei.library.startup.JeiStarter;

/**
 * Hands JEI's start to AsyncJeiStart when MCMETAL_ASYNC_JEI=1 (environment or mcmetal/options.txt); see
 * JeiStartTransformer.
 *
 * Not used as a class: JeiStartTransformer copies these static fields and methods into
 * mezz.jei.library.startup.JeiStarter (names prefixed "mcmetal$"). start() begins with "if (mcmetal$async(this))
 * return;" and stop() with "mcmetal$stopped();". AsyncJeiStart is defined next to JeiStarter from bytes the transformer
 * puts into asyncBytes(). No static initializer, lambdas or nested classes (they would not be copied).
 */
public final class JeiStartHooks {
    public static volatile int generation; // bumped by every start and stop; a build from an older one is dropped
    public static boolean usual;           // JEI's own start is running (the fallback)
    private static Class<?> async;
    private static int state;              // 0 not decided, 1 on, -1 off or broken

    private JeiStartHooks() {
    }

    /** Start of JeiStarter.start(): true when AsyncJeiStart took the start over. */
    public static boolean async(JeiStarter starter) {
        if (usual)
            return false;
        if (state == 0) {
            String on = System.getenv("MCMETAL_ASYNC_JEI");
            if (on == null)
                on = System.getProperty("mcmetal.opt.MCMETAL_ASYNC_JEI"); // mcmetal/options.txt
            state = "1".equals(on == null ? null : on.trim()) ? 1 : -1;
        }
        if (state < 0)
            return false;
        try {
            if (async == null)
                async = MethodHandles.lookup().defineClass(Base64.getDecoder().decode(asyncBytes()));
            return (Boolean) async.getMethod("start", JeiStarter.class).invoke(null, starter);
        } catch (java.lang.reflect.InvocationTargetException e) {
            System.out.println("[mcmetal] JEI's background start failed before it began, starting it the usual way: " + e.getCause());
            return false;
        } catch (Throwable t) {
            state = -1;
            System.out.println("[mcmetal] JEI's background start is not available (" + t + "), JEI starts the usual way");
            return false;
        }
    }

    /** Start of JeiStarter.stop(). */
    public static void stopped() {
        generation++;
    }

    /** Filled in by JeiStartTransformer with AsyncJeiStart's class file (renamed into JEI's package), in Base64. */
    private static String asyncBytes() {
        return null;
    }
}
