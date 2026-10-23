package mcmetal.loader;

import java.util.Set;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Caches the slow part of Minecraft's BiomeManager.getBiome(BlockPos) (on by default, MCMETAL_BIOME_CACHE=0 turns it
 * off). The border-blurring hash in getBiome was ~30% of the render thread's Java time with the Hearth & Hex mods
 * (M3 run J2) and hot on the world-generation threads while flying (J1). mcmetal.loader.biome.BiomeHooks is copied
 * into BiomeManager and getBiome starts with `h = mcmetal$biome(biomeZoomSeed, noiseBiomeSource, pos); if (h != null)
 * return h;`, which gives the same biome as the rest of the method (see BiomeHooks). Only Minecraft's BiomeManager
 * changes, in memory as it loads; no mod's jar is touched.
 */
final class BiomeTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "net.minecraft.world.level.biome.BiomeManager";
    static final String HOOKS = "mcmetal/loader/biome/BiomeHooks";
    static final String PREFIX = GpuCullTransformer.PREFIX;
    static final String SOURCE = "Lnet/minecraft/world/level/biome/BiomeManager$NoiseBiomeSource;";
    static final String GET_BIOME = "(Lnet/minecraft/core/BlockPos;)Lnet/minecraft/core/Holder;";

    static boolean wanted() {
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(System.getenv("MCMETAL_BIOME_CACHE"));
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        MethodNode get = null;
        for (MethodNode m : c.methods)
            if (m.name.equals("getBiome") && m.desc.equals(GET_BIOME))
                get = m;
        // the method must still be vanilla's: it hashes corners with getFiddledDistance and reads both fields
        boolean fiddles = false, seed = c.fields.stream().anyMatch(f -> f.name.equals("biomeZoomSeed") && f.desc.equals("J")),
                source = c.fields.stream().anyMatch(f -> f.name.equals("noiseBiomeSource") && f.desc.equals(SOURCE));
        if (get != null)
            for (AbstractInsnNode n : get.instructions.toArray())
                if (n instanceof MethodInsnNode mi && mi.owner.equals(c.name) && mi.name.equals("getFiddledDistance")
                        && mi.desc.equals("(JIIIDDD)D"))
                    fiddles = true;
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied: BiomeHooks must not have one
        if (get == null || !fiddles || !seed || !source || hooks == null) {
            MetalBootstrap.log("biome cache: Minecraft's BiomeManager is not the expected one, getBiome left as it is");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        String biomeDesc = "(J" + SOURCE + "Lnet/minecraft/core/BlockPos;)Lnet/minecraft/core/Holder;";
        LabelNode vanilla = new LabelNode();
        InsnList pre = new InsnList();
        pre.add(new VarInsnNode(Opcodes.ALOAD, 0));
        pre.add(new FieldInsnNode(Opcodes.GETFIELD, c.name, "biomeZoomSeed", "J"));
        pre.add(new VarInsnNode(Opcodes.ALOAD, 0));
        pre.add(new FieldInsnNode(Opcodes.GETFIELD, c.name, "noiseBiomeSource", SOURCE));
        pre.add(new VarInsnNode(Opcodes.ALOAD, 1));
        pre.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "biome", biomeDesc, false));
        pre.add(new InsnNode(Opcodes.DUP));
        pre.add(new JumpInsnNode(Opcodes.IFNULL, vanilla));
        pre.add(new InsnNode(Opcodes.ARETURN));
        pre.add(vanilla);
        pre.add(new FrameNode(Opcodes.F_SAME1, 0, null, 1, new Object[] {"net/minecraft/core/Holder"}));
        pre.add(new InsnNode(Opcodes.POP));
        get.instructions.insert(pre);
        get.maxStack = Math.max(get.maxStack, 5);
        MetalBootstrap.log("biome cache: getBiome's corner hashing is cached (MCMETAL_BIOME_CACHE)");
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
