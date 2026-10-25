package mcmetal.loader.dh;

import com.seibel.distanthorizons.api.methods.events.abstractEvents.DhApiBeforeGenericObjectRenderEvent;

/**
 * Distant Horizons' clouds stay out of the picture while mcmetal draws DH behind a pack without DH support (see
 * DhCompositeTransformer): the pack draws its own sky and clouds, and DH's blocky clouds would land on top of them.
 * DH's beacon beams still show. Iris does the same for packs with DH support whose clouds are on.
 *
 * Not used as a class: copied into DH's GlGenericObjectRenderer (names prefixed "mcmetal$"); dhSkip(cancel, param)
 * runs on the result of the "before generic object" event DH fires for each group of boxes, and the Iris side
 * calls dhMarkOn() through a method handle each frame it composites. Compiled against signature stubs in
 * mod/stubs; no static initializer, lambdas or nested classes.
 */
public final class DhGenericHooks {
    private static long dhOnAt; // System.nanoTime() of the last composited frame; 0 = never

    private DhGenericHooks() {
    }

    /** The Iris side drew DH behind the pack this frame. */
    public static void dhMarkOn() {
        dhOnAt = System.nanoTime();
    }

    /** DH's cancel flag for one group of boxes, also true for DH's clouds while the composite is on. */
    public static boolean dhSkip(boolean cancel, Object param) {
        if (cancel || dhOnAt == 0 || System.nanoTime() - dhOnAt > 1_000_000_000L) // shaders off: DH as usual
            return cancel;
        return param instanceof DhApiBeforeGenericObjectRenderEvent.EventParam p && "Clouds".equalsIgnoreCase(p.resourceLocationPath);
    }
}
