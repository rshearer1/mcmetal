package mcmetal.loader.load.jei;

import net.minecraft.client.Minecraft;

/**
 * JEI's "only on the render thread" check, also passing AsyncJeiStart's thread (see JeiStartTransformer).
 *
 * Not used as a class: JeiStartTransformer copies this static method into mezz.jei.common.util.ErrorUtil (name
 * prefixed "mcmetal$"), where assertMainThread() asks it instead of minecraft.isSameThread(). JEI guards its
 * ingredient and recipe managers with that check; while the background start builds them, that thread is their only
 * user. Every other thread is still refused. No static initializer, lambdas or nested classes.
 */
public final class JeiThreadHooks {
    private JeiThreadHooks() {
    }

    /** Stands in for minecraft.isSameThread(). */
    public static boolean isSameThread(Minecraft minecraft) {
        return minecraft.isSameThread() || "mcmetal JEI start".equals(Thread.currentThread().getName());
    }
}
