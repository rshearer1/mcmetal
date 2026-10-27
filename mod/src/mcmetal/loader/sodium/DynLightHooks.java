package mcmetal.loader.sodium;

import java.lang.reflect.Method;
import java.nio.FloatBuffer;
import java.util.WeakHashMap;

import net.caffeinemc.mods.sodium.client.render.chunk.DefaultChunkRenderer;
import net.caffeinemc.mods.sodium.client.render.viewport.CameraTransform;
import org.lwjgl.opengl.GL20;
import org.lwjgl.system.MemoryUtil;

/**
 * Dynamic lights on the GPU, Sodium side (see DynLightTransformer). Not used as a class: copied into Sodium's
 * DefaultChunkRenderer (names prefixed "mcmetal$"), like CullHooks; DynLightShaderHooks puts the light list in the shader.
 *
 * lights() runs once the pass's program is bound: it asks LambDynamicLights for
 * the lights near the camera (LdlHooks, copied into LambDynLights) and hands them to the program. With a shader pack
 * in use (Iris draws terrain with the pack's programs), or if anything is missing, it tells LambDynamicLights to keep
 * its own way: chunk meshes rebuilt around each moving light.
 * No static initializer, lambdas or nested classes (they would not be copied); every field starts at its default.
 */
public final class DynLightHooks {
    static final int MAX = 32; // lights per frame, nearest first (a vec4 each)

    private static int dlState;          // 0 not looked up yet, 1 ready, -1 off (no LambDynamicLights)
    private static Method dlLights;      // LambDynLights.mcmetal$lights(float[], boolean, double, double, double)
    private static Method dlIris;        // Iris.isPackInUseQuick(), null without Iris
    private static float[] dlBuf;
    private static FloatBuffer dlUpload;
    private static WeakHashMap<Object, int[]> dlPrograms; // Sodium's program -> locations of the list and the count

    private DynLightHooks() {
    }

    /** Called by DefaultChunkRenderer.render() right after the pass's program is bound. */
    public static void lights(DefaultChunkRenderer self, CameraTransform camera) {
        if (dlState < 0)
            return;
        if (dlState == 0 && !dlStart(self))
            return;
        try {
            boolean pack = dlIris != null && (Boolean) dlIris.invoke(null);
            int[] loc = pack || self.activeProgram == null ? null : dlPrograms.get(self.activeProgram);
            if (loc == null && !pack && self.activeProgram != null) {
                int p = self.activeProgram.handle();
                loc = new int[] {GL20.glGetUniformLocation(p, "u_McmDynLights"), GL20.glGetUniformLocation(p, "u_McmDynLightCount")};
                dlPrograms.put(self.activeProgram, loc);
            }
            boolean gpu = loc != null && loc[0] >= 0 && loc[1] >= 0;
            int n = (Integer) dlLights.invoke(null, dlBuf, gpu, camera.intX + (double) camera.fracX,
                    camera.intY + (double) camera.fracY, camera.intZ + (double) camera.fracZ);
            if (!gpu)
                return;
            if (n > 0) {
                dlUpload.clear();
                dlUpload.put(dlBuf, 0, n * 4).flip();
                GL20.glUniform4fv(loc[0], dlUpload);
            }
            GL20.glUniform1i(loc[1], n);
        } catch (ReflectiveOperationException | RuntimeException e) {
            dlState = -1;
            System.out.println("[mcmetal] dynamic lights: " + e + ", lights stay on the CPU");
        }
    }

    private static boolean dlStart(DefaultChunkRenderer self) {
        try {
            ClassLoader cl = self.getClass().getClassLoader();
            dlLights = Class.forName("dev.lambdaurora.lambdynlights.LambDynLights", false, cl).getMethod("mcmetal$lights",
                    float[].class, boolean.class, double.class, double.class, double.class);
            try {
                dlIris = Class.forName("net.irisshaders.iris.Iris", false, cl).getMethod("isPackInUseQuick");
            } catch (ReflectiveOperationException e) {
                dlIris = null; // no Iris: Sodium's own programs always
            }
        } catch (ReflectiveOperationException | LinkageError e) {
            dlState = -1; // no LambDynamicLights (or not patched): nothing to do
            return false;
        }
        dlBuf = new float[MAX * 4];
        dlUpload = MemoryUtil.memAllocFloat(MAX * 4); // lives as long as the game
        dlPrograms = new WeakHashMap<>();
        dlState = 1;
        System.out.println("[mcmetal] dynamic lights: LambDynamicLights' lights are drawn in Sodium's terrain shader"
                + " (no chunk rebuilds as they move; MCMETAL_DYN_LIGHTS=0 turns this off)");
        return true;
    }
}
