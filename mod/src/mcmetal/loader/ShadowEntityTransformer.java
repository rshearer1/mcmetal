package mcmetal.loader;

import java.util.Set;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Leaves small, far entities out of Iris's shadow pass (off by default, MCMETAL_SHADOW_ENTITY_LOD=32 turns it on;
 * see mcmetal.loader.iris.ShadowEntityHooks for the rule). Copies the hooks into Iris's ShadowRenderer and swaps two
 * calls: EntityRenderDispatcher.shouldRender in renderEntities() (the player-only path is left alone) and
 * BlockEntityRenderDispatcher.render in renderBlockEntities(), which also gets the camera position. Iris's jar is
 * never changed; with the switch off, or an Iris that doesn't look as expected, the class is left exactly as it is.
 */
final class ShadowEntityTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "net.irisshaders.iris.shadows.ShadowRenderer";
    static final String HOOKS = "mcmetal/loader/iris/ShadowEntityHooks";
    static final String PREFIX = GpuCullTransformer.PREFIX;
    static final String ENTITY_DISPATCHER = "net/minecraft/client/renderer/entity/EntityRenderDispatcher";
    static final String SHOULD_RENDER = "(Lnet/minecraft/world/entity/Entity;Lnet/minecraft/client/renderer/culling/Frustum;DDD)Z";
    static final String BLOCK_DISPATCHER = "net/minecraft/client/renderer/blockentity/BlockEntityRenderDispatcher";
    static final String BLOCK_RENDER = "(Lnet/minecraft/world/level/block/entity/BlockEntity;FLcom/mojang/blaze3d/vertex/PoseStack;"
            + "Lnet/minecraft/client/renderer/MultiBufferSource;)V";
    // renderBlockEntities(RenderBuffers, PoseStack, Camera, double cameraX, double cameraY, double cameraZ, float, boolean, boolean)
    static final String BLOCKS_DESC = "(Lnet/minecraft/client/renderer/RenderBuffers;Lcom/mojang/blaze3d/vertex/PoseStack;"
            + "Lnet/minecraft/client/Camera;DDDFZZ)I";

    static boolean wanted() {
        String v = System.getenv("MCMETAL_SHADOW_ENTITY_LOD");
        if (v == null)
            v = System.getProperty("mcmetal.opt.MCMETAL_SHADOW_ENTITY_LOD");
        // off unless set: the GitHub Mac A/B (run 39958449866) showed no fps change, M3 run EN1 decides
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && v != null && !v.trim().isEmpty() && !"0".equals(v.trim());
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        MethodInsnNode entityCall = null, blockCall = null;
        MethodNode entities = null, blocks = null;
        for (MethodNode m : c.methods) {
            if (m.name.equals("renderEntities") && m.desc.startsWith("(Lnet/irisshaders/iris/mixin/LevelRendererAccessor;L" + ENTITY_DISPATCHER + ";"))
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEVIRTUAL && mi.owner.equals(ENTITY_DISPATCHER)
                            && mi.name.equals("shouldRender") && mi.desc.equals(SHOULD_RENDER)) {
                        entityCall = entityCall == null ? mi : null; // exactly one, or leave it alone
                        entities = m;
                    }
            if (m.name.equals("renderBlockEntities") && m.desc.equals(BLOCKS_DESC) && (m.access & Opcodes.ACC_STATIC) == 0)
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEVIRTUAL && mi.owner.equals(BLOCK_DISPATCHER)
                            && mi.name.equals("render") && mi.desc.equals(BLOCK_RENDER)) {
                        blockCall = blockCall == null ? mi : null;
                        blocks = m;
                    }
        }
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied: ShadowEntityHooks must not have one
        if (entityCall == null || hooks == null) {
            MetalBootstrap.log("shadow pass: Iris's ShadowRenderer is not the expected one, every entity keeps its shadow");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        // dispatcher.shouldRender(entity, frustum, x, y, z)  ->  mcmetal$shouldRender(dispatcher, entity, frustum, x, y, z)
        entities.instructions.set(entityCall, new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "shouldRender",
                "(L" + ENTITY_DISPATCHER + ";" + SHOULD_RENDER.substring(1), false));
        if (blockCall != null) {
            // dispatcher.render(be, tick, pose, buffers)  ->  mcmetal$renderBlockEntity(dispatcher, be, tick, pose, buffers, cameraX, cameraY, cameraZ)
            InsnList cam = new InsnList();
            for (int slot : new int[] {4, 6, 8})
                cam.add(new VarInsnNode(Opcodes.DLOAD, slot));
            blocks.instructions.insertBefore(blockCall, cam);
            blocks.instructions.set(blockCall, new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "renderBlockEntity",
                    "(L" + BLOCK_DISPATCHER + ";" + BLOCK_RENDER.substring(1, BLOCK_RENDER.indexOf(')')) + "DDD)V", false));
            blocks.maxStack += 6;
        }
        MetalBootstrap.log("shadow pass: small, far entities" + (blockCall != null ? " and block entities" : "")
                + " are left out of Iris's shadow map (MCMETAL_SHADOW_ENTITY_LOD)");
        return c;
    }

    @Override
    public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
        return TransformerVoteResult.YES;
    }

    @Override
    public Set<Target<ClassNode>> targets() {
        return Set.of(Target.targetClass(TARGET));
    }

    @Override
    public TargetType<ClassNode> getTargetType() {
        return TargetType.CLASS;
    }
}
