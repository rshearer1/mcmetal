// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.minecraft.client.renderer.blockentity;
// getRenderBoundingBox really comes from NeoForge's IBlockEntityRendererExtension, which BlockEntityRenderer extends
public interface BlockEntityRenderer<T extends net.minecraft.world.level.block.entity.BlockEntity> {
    default net.minecraft.world.phys.AABB getRenderBoundingBox(T blockEntity) { throw new AssertionError(); }
}
