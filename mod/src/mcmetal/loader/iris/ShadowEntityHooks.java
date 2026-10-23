package mcmetal.loader.iris;

import com.mojang.blaze3d.vertex.PoseStack;
import net.minecraft.client.renderer.MultiBufferSource;
import net.minecraft.client.renderer.blockentity.BlockEntityRenderDispatcher;
import net.minecraft.client.renderer.blockentity.BlockEntityRenderer;
import net.minecraft.client.renderer.culling.Frustum;
import net.minecraft.client.renderer.entity.EntityRenderDispatcher;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.block.entity.BlockEntity;
import net.minecraft.world.phys.AABB;

/**
 * Small, far entities left out of Iris's shadow pass (on by default, MCMETAL_SHADOW_ENTITY_LOD=0 turns it off).
 *
 * Iris draws every entity and block entity the main view would draw a second time into the shadow map, posing each
 * model again in Java. Minecraft already stops drawing an entity once it is farther than ~64x its size; in the
 * shadow pass this keeps only those within MCMETAL_SHADOW_ENTITY_LOD (default 32) times their largest side: a
 * chicken's shadow goes at ~22 blocks, a cow's at ~45, a villager's at ~62, a chest's at 32. Past that the shadow
 * would be a few pixels across. Players are always kept. Halving the distance leaves out about 3/4 of the shadow
 * entities in a busy farm.
 *
 * Not used as a class: ShadowEntityTransformer copies these static fields and methods into Iris's ShadowRenderer
 * (names prefixed "mcmetal$") and points its shouldRender() and block entity render() calls at them. Compiled
 * against signature stubs in mod/stubs; no static initializer, lambdas or nested classes (they would not be copied).
 */
public final class ShadowEntityHooks {
    private static double lod2;     // (LOD)^2; 0 = not read yet, -1 = off
    private static int kept, skipped, keptBlocks, skippedBlocks;
    private static long lastLog;
    private static double farthest2;  // (distance / size)^2 of the farthest entity seen since the last log line

    private ShadowEntityHooks() {
    }

    /** In place of dispatcher.shouldRender(entity, frustum, x, y, z) in ShadowRenderer.renderEntities. */
    public static boolean shouldRender(EntityRenderDispatcher dispatcher, Entity entity, Frustum frustum,
                                       double x, double y, double z) {
        if (!dispatcher.shouldRender(entity, frustum, x, y, z))
            return false;
        double n2 = lod2 == 0 ? start() : lod2;
        if (n2 < 0 || entity instanceof Player)
            return true;
        boolean keep = near(entity.getBoundingBox(), n2, x, y, z);
        if (keep)
            kept++;
        else
            skipped++;
        log();
        return keep;
    }

    /** In place of dispatcher.render(blockEntity, tick, pose, buffers) in ShadowRenderer.renderBlockEntities. */
    public static void renderBlockEntity(BlockEntityRenderDispatcher dispatcher, BlockEntity blockEntity, float tick,
                                         PoseStack pose, MultiBufferSource buffers, double x, double y, double z) {
        double n2 = lod2 == 0 ? start() : lod2;
        if (n2 > 0) {
            AABB box = null;
            try {
                BlockEntityRenderer<BlockEntity> r = dispatcher.getRenderer(blockEntity);
                if (r != null)
                    box = r.getRenderBoundingBox(blockEntity);
            } catch (Throwable t) { // not NeoForge's renderer extension after all: keep every block entity
                lod2 = -1;
            }
            log();
            if (box != null && !near(box, n2, x, y, z)) {
                skippedBlocks++;
                return;
            }
            keptBlocks++;
        }
        dispatcher.render(blockEntity, tick, pose, buffers);
    }

    /** Within LOD times the box's largest side of the camera (always, for boxes with no size or no end). */
    private static boolean near(AABB b, double n2, double x, double y, double z) {
        double size = Math.max(b.maxX - b.minX, Math.max(b.maxY - b.minY, b.maxZ - b.minZ));
        if (!(size > 0) || Double.isInfinite(size))
            return true;
        double dx = (b.minX + b.maxX) * 0.5 - x, dy = (b.minY + b.maxY) * 0.5 - y, dz = (b.minZ + b.maxZ) * 0.5 - z;
        double r2 = (dx * dx + dy * dy + dz * dz) / (size * size);
        farthest2 = Math.max(farthest2, r2);
        return r2 <= n2;
    }

    private static double start() {
        String v = System.getenv("MCMETAL_SHADOW_ENTITY_LOD");
        if (v == null)
            v = System.getProperty("mcmetal.opt.MCMETAL_SHADOW_ENTITY_LOD"); // mcmetal/options.txt
        double n = 32;
        try {
            if (v != null)
                n = Double.parseDouble(v.trim());
        } catch (NumberFormatException e) {
            // keep the default
        }
        lod2 = n > 0 ? n * n : -1;
        System.out.println("[mcmetal] shadow pass: " + (n > 0 ? "entities and block entities farther than " + n
                + "x their size are left out (MCMETAL_SHADOW_ENTITY_LOD)" : "every entity is drawn (MCMETAL_SHADOW_ENTITY_LOD=0)"));
        return lod2;
    }

    /** Every 30 s: how many shadow-pass draws were left out (counts are per entity per frame). */
    private static void log() {
        long now = System.nanoTime();
        if (lastLog == 0)
            lastLog = now;
        if (now - lastLog < 30_000_000_000L)
            return;
        lastLog = now;
        System.out.println("[mcmetal] shadow pass, last 30 s: " + skipped + " of " + (kept + skipped)
                + " entity draws and " + skippedBlocks + " of " + (keptBlocks + skippedBlocks)
                + " block entity draws left out (MCMETAL_SHADOW_ENTITY_LOD), farthest " + Math.round(Math.sqrt(farthest2))
                + "x its size");
        kept = skipped = keptBlocks = skippedBlocks = 0;
        farthest2 = 0;
    }
}
