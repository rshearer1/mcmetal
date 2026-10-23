// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.minecraft.client.renderer.entity;
public class EntityRenderDispatcher {
    public <E extends net.minecraft.world.entity.Entity> boolean shouldRender(E entity, net.minecraft.client.renderer.culling.Frustum frustum,
            double x, double y, double z) { throw new AssertionError(); }
}
