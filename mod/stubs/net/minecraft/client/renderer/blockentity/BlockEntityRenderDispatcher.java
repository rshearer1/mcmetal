// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.minecraft.client.renderer.blockentity;
import net.minecraft.world.level.block.entity.BlockEntity;
public class BlockEntityRenderDispatcher {
    public <E extends BlockEntity> BlockEntityRenderer<E> getRenderer(E blockEntity) { throw new AssertionError(); }
    public <E extends BlockEntity> void render(E blockEntity, float partialTick, com.mojang.blaze3d.vertex.PoseStack poseStack,
            net.minecraft.client.renderer.MultiBufferSource bufferSource) { throw new AssertionError(); }
}
