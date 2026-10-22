// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.caffeinemc.mods.sodium.client.render.chunk.region;
import net.caffeinemc.mods.sodium.client.render.chunk.terrain.TerrainRenderPass;
public class RenderRegion {
    public int getOriginX() { throw new AssertionError(); }
    public int getOriginY() { throw new AssertionError(); }
    public int getOriginZ() { throw new AssertionError(); }
    public net.caffeinemc.mods.sodium.client.render.chunk.data.SectionRenderDataStorage getStorage(TerrainRenderPass p) { throw new AssertionError(); }
    public DeviceResources getResources() { throw new AssertionError(); }
    public net.caffeinemc.mods.sodium.client.gl.device.MultiDrawBatch getCachedBatch(TerrainRenderPass p) { throw new AssertionError(); }
    public static class DeviceResources { public net.caffeinemc.mods.sodium.client.gl.buffer.GlBuffer getIndexBuffer() { throw new AssertionError(); } }
}
