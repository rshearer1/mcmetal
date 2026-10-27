package mcmetal.loader.ldl;

import dev.lambdaurora.lambdynlights.LambDynLights;
import dev.lambdaurora.lambdynlights.engine.source.DynamicLightSource;
import dev.lambdaurora.lambdynlights.engine.source.EntityDynamicLightSource;
import net.minecraft.client.Minecraft;

/**
 * Dynamic lights on the GPU, LambDynamicLights side (see DynLightTransformer). Not used as a class: copied into
 * LambDynLights (names prefixed "mcmetal$") so it can read the mod's own light list.
 *
 * gpu says Sodium's terrain shader draws the lights this frame. While it is set, LambDynLights leaves dynamic light
 * out of chunk meshes (getLightmapWithDynamicLight returns the world's own light for anything but the ClientLevel,
 * i.e. for Sodium's mesh builders) and its ChunkRebuildScheduler asks for no rebuilds. Mobs, block entities and
 * particles near a light still get it from LambDynamicLights every frame, as before.
 * No static initializer, lambdas or nested classes (they would not be copied); every field starts at its default.
 */
public final class LdlHooks {
    public static volatile boolean gpu;

    private LdlHooks() {
    }

    /**
     * Called by Sodium's DefaultChunkRenderer once a terrain pass's program is bound. wantGpu: that program has the
     * light list (no shader pack). Fills out with up to out.length / 4 lights (x, y, z from the camera, luminance),
     * nearest first, and returns how many; 0 without wantGpu.
     */
    public static int lights(float[] out, boolean wantGpu, double cx, double cy, double cz) {
        LambDynLights ldl = LambDynLights.get();
        if (wantGpu != gpu) {
            gpu = wantGpu;
            remesh(ldl); // meshes near lights were built the other way: light baked in, or left out
        }
        if (!wantGpu || !ldl.config.getDynamicLightsMode().isEnabled())
            return 0;
        int n = 0, max = out.length / 4;
        ldl.lightSourcesLock.readLock().lock();
        try {
            for (DynamicLightSource s : ldl.dynamicLightSources) {
                if (!(s instanceof EntityDynamicLightSource e))
                    continue; // beacon beams, guardian lasers...: lines, not points (not drawn on this path)
                int lum = e.getLuminance();
                if (lum <= 0)
                    continue;
                float x = (float) (e.getDynamicLightX() - cx), y = (float) (e.getDynamicLightY() - cy), z = (float) (e.getDynamicLightZ() - cz);
                float d = x * x + y * y + z * z;
                int at = n;
                if (n == max) { // full: replace the farthest if this one is nearer
                    at = -1;
                    float far = d;
                    for (int i = 0; i < n; i++) {
                        float xi = out[i * 4], yi = out[i * 4 + 1], zi = out[i * 4 + 2], di = xi * xi + yi * yi + zi * zi;
                        if (di > far) {
                            far = di;
                            at = i;
                        }
                    }
                    if (at < 0)
                        continue;
                } else {
                    n++;
                }
                out[at * 4] = x;
                out[at * 4 + 1] = y;
                out[at * 4 + 2] = z;
                out[at * 4 + 3] = lum;
            }
        } finally {
            ldl.lightSourcesLock.readLock().unlock();
        }
        return n;
    }

    /** Asks for the chunk sections within reach of each light to be built again (when the way they are lit changes). */
    private static void remesh(LambDynLights ldl) {
        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.levelRenderer == null)
            return;
        ldl.lightSourcesLock.readLock().lock();
        try {
            for (DynamicLightSource s : ldl.dynamicLightSources) {
                if (!(s instanceof EntityDynamicLightSource e))
                    continue;
                int x0 = ((int) Math.floor(e.getDynamicLightX() - 8)) >> 4, x1 = ((int) Math.floor(e.getDynamicLightX() + 8)) >> 4;
                int y0 = ((int) Math.floor(e.getDynamicLightY() - 8)) >> 4, y1 = ((int) Math.floor(e.getDynamicLightY() + 8)) >> 4;
                int z0 = ((int) Math.floor(e.getDynamicLightZ() - 8)) >> 4, z1 = ((int) Math.floor(e.getDynamicLightZ() + 8)) >> 4;
                for (int x = x0; x <= x1; x++)
                    for (int y = y0; y <= y1; y++)
                        for (int z = z0; z <= z1; z++)
                            mc.levelRenderer.setSectionDirty(x, y, z);
            }
        } finally {
            ldl.lightSourcesLock.readLock().unlock();
        }
    }
}
