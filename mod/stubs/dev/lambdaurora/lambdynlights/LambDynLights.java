// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package dev.lambdaurora.lambdynlights;
public class LambDynLights {
    public final DynamicLightsConfig config = null;
    public final java.util.Set<dev.lambdaurora.lambdynlights.engine.source.DynamicLightSource> dynamicLightSources = null;
    public final java.util.concurrent.locks.ReentrantReadWriteLock lightSourcesLock = null;
    public static LambDynLights get() { return null; }
}
