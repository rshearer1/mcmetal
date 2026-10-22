package mcmetal.loader.sodium;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Iterator;
import java.util.WeakHashMap;

import net.caffeinemc.mods.sodium.client.gl.device.CommandList;
import net.caffeinemc.mods.sodium.client.gl.device.MultiDrawBatch;
import net.caffeinemc.mods.sodium.client.render.chunk.ChunkRenderMatrices;
import net.caffeinemc.mods.sodium.client.render.chunk.DefaultChunkRenderer;
import net.caffeinemc.mods.sodium.client.render.chunk.LocalSectionIndex;
import net.caffeinemc.mods.sodium.client.render.chunk.data.SectionRenderDataStorage;
import net.caffeinemc.mods.sodium.client.render.chunk.data.SectionRenderDataUnsafe;
import net.caffeinemc.mods.sodium.client.render.chunk.lists.ChunkRenderList;
import net.caffeinemc.mods.sodium.client.render.chunk.lists.ChunkRenderListIterable;
import net.caffeinemc.mods.sodium.client.render.chunk.region.RenderRegion;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.TerrainRenderPass;
import net.caffeinemc.mods.sodium.client.render.viewport.CameraTransform;
import net.caffeinemc.mods.sodium.client.util.iterator.ByteIterator;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.lwjgl.opengl.GL;
import org.lwjgl.system.JNI;
import org.lwjgl.system.MemoryUtil;

/**
 * GPU chunk culling, Java side (on unless MCMETAL_GPU_CULL=0; see core/mgl_cull.c for the other half).
 *
 * Not used as a class: GpuCullTransformer copies these static fields and methods into Sodium's DefaultChunkRenderer
 * (names prefixed "mcmetal$") so they run in the game's class space, and calls prepare() at the top of its render()
 * and finish() before it returns. prepare() hands mcmetal every region the pass is about to draw whose draw list
 * Sodium has already built: the list's arrays, its index buffer, where the region is and which section each draw
 * belongs to. Regions whose list Sodium (re)builds inside render() are simply drawn the normal way this frame.
 * Compiled against signature stubs in mod/stubs; no static initializer, lambdas or nested classes (they would not
 * be copied), so every field starts at its default value.
 */
public final class CullHooks {
    private static final int HEADER = 128, REGION = 64, SECTION = 16, FACINGS = 7;

    private static long fn;                 // mcmGpuCull in mcmetal; 0 = not looked up yet, -1 = culling off
    private static long buf;                // native command: header + region records
    private static int cap;
    private static long endCmd;             // native "pass finished" command
    private static boolean prepared;
    private static int iris;                // Iris (its shadow pass state): 0 not checked, 1 present, 2 absent
    private static WeakHashMap<MultiDrawBatch, Object[]> tables; // batch -> {section table, signature}

    private CullHooks() {
    }

    public static void prepare(DefaultChunkRenderer self, ChunkRenderMatrices matrices, CommandList commandList,
                               ChunkRenderListIterable renderLists, TerrainRenderPass pass, CameraTransform camera,
                               boolean indexedRenderingEnabled) {
        if (fn == -1)
            return;
        if (fn == 0 && !start())
            return;
        boolean indexed = pass.isTranslucent() && indexedRenderingEnabled;
        int n = 0;
        Iterator<ChunkRenderList> it = renderLists.iterator(pass.isTranslucent()); // render()'s order
        while (it.hasNext()) {
            ChunkRenderList list = it.next();
            RenderRegion region = list.getRegion();
            SectionRenderDataStorage storage = region.getStorage(pass);
            RenderRegion.DeviceResources resources = storage == null ? null : region.getResources();
            if (resources == null)
                continue;
            MultiDrawBatch batch = region.getCachedBatch(pass);
            if (!batch.isFilled || batch.size <= 0)
                continue; // render() fills it now; drawn normally this time
            Object[] table = table(batch, list, storage, pass);
            if (table == null)
                continue;
            if (HEADER + (n + 1) * REGION > cap)
                grow(HEADER + (n + 1) * REGION * 2);
            long r = buf + HEADER + (long) n * REGION;
            MemoryUtil.memPutLong(r, batch.pElementCount);
            MemoryUtil.memPutLong(r + 8, batch.pElementPointer);
            MemoryUtil.memPutLong(r + 16, batch.pBaseVertex);
            MemoryUtil.memPutLong(r + 24, MemoryUtil.memAddress((ByteBuffer) table[0]));
            MemoryUtil.memPutInt(r + 32, batch.size);
            MemoryUtil.memPutInt(r + 36, ((int[]) table[1])[4]);
            MemoryUtil.memPutInt(r + 40, indexed ? resources.getIndexBuffer().handle()
                    : self.sharedIndexBuffer.getBufferObject().handle());
            // the same camera-relative origin Sodium gives the shader (u_RegionOffset)
            MemoryUtil.memPutFloat(r + 48, (float) (region.getOriginX() - camera.intX) - camera.fracX);
            MemoryUtil.memPutFloat(r + 52, (float) (region.getOriginY() - camera.intY) - camera.fracY);
            MemoryUtil.memPutFloat(r + 56, (float) (region.getOriginZ() - camera.intZ) - camera.fracZ);
            n++;
        }
        // sent even with nothing to prepare: mcmetal needs to know a translucent pass is about to draw
        boolean shadow = false;
        if (iris == 0)
            iris = present("net.irisshaders.iris.shadows.ShadowRenderingState") ? 1 : 2;
        if (iris == 1)
            shadow = net.irisshaders.iris.shadows.ShadowRenderingState.areShadowsCurrentlyBeingRendered();
        MemoryUtil.memPutInt(buf, 1);
        MemoryUtil.memPutInt(buf + 4, (shadow ? 1 : 0) | (pass.isTranslucent() ? 2 : 0));
        MemoryUtil.memPutInt(buf + 8, n);
        MemoryUtil.memPutInt(buf + 12, 2);
        Matrix4f mvp = new Matrix4f(matrices.projection()).mul(matrices.modelView());
        putMatrix(buf + 16, mvp);
        // camera position, for the next frame's occlusion test against this frame's depth
        MemoryUtil.memPutDouble(buf + 80, camera.intX + (double) camera.fracX);
        MemoryUtil.memPutDouble(buf + 88, camera.intY + (double) camera.fracY);
        MemoryUtil.memPutDouble(buf + 96, camera.intZ + (double) camera.fracZ);
        prepared = JNI.invokePP(buf, fn) > 0;
    }

    public static void finish() {
        if (!prepared)
            return;
        prepared = false;
        JNI.invokePP(endCmd, fn);
    }

    private static boolean start() {
        fn = -1;
        String on = System.getenv("MCMETAL_GPU_CULL");
        if ("0".equals(on) || GL.getFunctionProvider() == null)
            return false;
        long f = GL.getFunctionProvider().getFunctionAddress("mcmGpuCull");
        if (f == 0) { // not mcmetal (Apple's OpenGL fallback), or a GL wrapper in front of it
            System.out.println("[mcmetal] GPU chunk culling: mcmGpuCull not found in the GL library, culling stays off");
            return false;
        }
        endCmd = MemoryUtil.nmemCalloc(1, HEADER);
        MemoryUtil.memPutInt(endCmd, 2);
        MemoryUtil.memPutInt(endCmd + 12, 2);
        tables = new WeakHashMap<>();
        grow(HEADER + 256 * REGION);
        fn = f;
        return true;
    }

    private static void grow(int size) {
        buf = MemoryUtil.nmemRealloc(buf, size);
        cap = size;
    }

    private static boolean present(String name) {
        try {
            Class.forName(name, false, DefaultChunkRenderer.class.getClassLoader());
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private static void putMatrix(long p, Matrix4fc m) {
        float[] v = {m.m00(), m.m01(), m.m02(), m.m03(), m.m10(), m.m11(), m.m12(), m.m13(),
                     m.m20(), m.m21(), m.m22(), m.m23(), m.m30(), m.m31(), m.m32(), m.m33()};
        for (int i = 0; i < 16; i++)
            MemoryUtil.memPutFloat(p + i * 4L, v[i]);
    }

    /**
     * Which vertices belong to which section, in the order Sodium filled the batch (the list's order), as
     * {ByteBuffer of [start, end, x | y << 8 | z << 16, 0] per section, int[] {size, hashes, 0, count}}. Rebuilt when
     * the batch's draws change.
     */
    private static Object[] table(MultiDrawBatch batch, ChunkRenderList list, SectionRenderDataStorage storage,
                                  TerrainRenderPass pass) {
        int h1 = 1, h2 = 1; // the batch's ranges: a section rebuilt elsewhere in the region buffer changes them
        for (int i = 0; i < batch.size; i++) {
            h1 = h1 * 31 + MemoryUtil.memGetInt(batch.pBaseVertex + i * 4L);
            h2 = h2 * 31 + MemoryUtil.memGetInt(batch.pElementCount + i * 4L);
        }
        Object[] t = tables.get(batch);
        if (t != null) {
            int[] sig = (int[]) t[1];
            if (sig[0] == batch.size && sig[1] == h1 && sig[2] == h2)
                return t;
        }
        ByteIterator it = list.sectionsWithGeometryIterator(pass.isTranslucent());
        if (it == null)
            return null;
        ByteBuffer b = t != null ? (ByteBuffer) t[0] : ByteBuffer.allocateDirect(256 * SECTION).order(ByteOrder.nativeOrder());
        long p = MemoryUtil.memAddress(b);
        int n = 0;
        while (it.hasNext() && n < 256) {
            int section = it.nextByteAsInt();
            long mesh = storage.getDataPointer(section);
            long start = SectionRenderDataUnsafe.getBaseVertex(mesh), count = 0;
            for (int f = 0; f < FACINGS; f++)
                count += SectionRenderDataUnsafe.getVertexCount(mesh, f);
            long e = p + (long) n * SECTION;
            MemoryUtil.memPutInt(e, (int) start);
            MemoryUtil.memPutInt(e + 4, (int) (start + count));
            MemoryUtil.memPutInt(e + 8, LocalSectionIndex.unpackX(section) | LocalSectionIndex.unpackY(section) << 8
                    | LocalSectionIndex.unpackZ(section) << 16);
            n++;
        }
        t = new Object[] {b, new int[] {batch.size, h1, h2, 0, n}};
        tables.put(batch, t);
        return t;
    }
}
