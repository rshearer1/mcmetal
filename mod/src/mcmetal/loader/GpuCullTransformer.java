package mcmetal.loader;

import java.io.IOException;
import java.io.InputStream;
import java.util.Set;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FieldNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * GPU chunk culling (on by default, MCMETAL_GPU_CULL=0 turns it off): copies mcmetal.loader.sodium.CullHooks into Sodium's DefaultChunkRenderer
 * and calls its prepare() at the top of render() and finish() before render() returns. Sodium's jar is never
 * changed; this happens in memory as the class loads, like the Iris patches next door. With the switch off the class
 * is left exactly as it is.
 */
final class GpuCullTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "net.caffeinemc.mods.sodium.client.render.chunk.DefaultChunkRenderer";
    static final String HOOKS = "mcmetal/loader/sodium/CullHooks";
    static final String PREFIX = "mcmetal$";
    static final String RENDER_DESC = "(Lnet/caffeinemc/mods/sodium/client/render/chunk/ChunkRenderMatrices;"
            + "Lnet/caffeinemc/mods/sodium/client/gl/device/CommandList;"
            + "Lnet/caffeinemc/mods/sodium/client/render/chunk/lists/ChunkRenderListIterable;"
            + "Lnet/caffeinemc/mods/sodium/client/render/chunk/terrain/TerrainRenderPass;"
            + "Lnet/caffeinemc/mods/sodium/client/render/viewport/CameraTransform;Z)V";

    static boolean wanted() {
        String on = System.getenv("MCMETAL_GPU_CULL");
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(on);
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        MethodNode render = null;
        for (MethodNode m : c.methods)
            if (m.name.equals("render") && m.desc.equals(RENDER_DESC))
                render = m;
        ClassNode hooks = readHooks();
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied: CullHooks must not have one
        if (render == null || hooks == null) {
            MetalBootstrap.log("GPU chunk culling: Sodium's DefaultChunkRenderer is not the expected one, culling stays off");
            return c;
        }
        merge(hooks, c);
        String prepareDesc = "(L" + c.name + ";" + RENDER_DESC.substring(1);
        InsnList pre = new InsnList();
        for (int i = 0; i <= 5; i++)
            pre.add(new VarInsnNode(Opcodes.ALOAD, i));
        pre.add(new VarInsnNode(Opcodes.ILOAD, 6));
        pre.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "prepare", prepareDesc, false));
        render.instructions.insert(pre);
        for (AbstractInsnNode n : render.instructions.toArray())
            if (n.getOpcode() == Opcodes.RETURN)
                render.instructions.insertBefore(n, new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "finish", "()V", false));
        render.maxStack = Math.max(render.maxStack, 7);
        MetalBootstrap.log("GPU chunk culling: Sodium terrain passes are culled on the GPU (MCMETAL_GPU_CULL)");
        return c;
    }

    private static ClassNode readHooks() {
        try (InputStream in = GpuCullTransformer.class.getResourceAsStream("/" + HOOKS + ".class")) {
            if (in == null)
                return null;
            ClassNode n = new ClassNode();
            new ClassReader(in.readAllBytes()).accept(n, 0);
            return n;
        } catch (IOException e) {
            return null;
        }
    }

    /** Static fields and methods of `from` into `to`, renamed with PREFIX, with references to `from` pointed at `to`. */
    private static void merge(ClassNode from, ClassNode to) {
        for (FieldNode f : from.fields)
            if ((f.access & Opcodes.ACC_STATIC) != 0)
                to.fields.add(new FieldNode(f.access, PREFIX + f.name, f.desc, f.signature, f.value));
        for (MethodNode m : from.methods) {
            if ((m.access & Opcodes.ACC_STATIC) == 0 || m.name.startsWith("<"))
                continue;
            m.name = PREFIX + m.name;
            for (AbstractInsnNode n : m.instructions.toArray()) {
                if (n instanceof FieldInsnNode f && f.owner.equals(from.name)) {
                    f.owner = to.name;
                    f.name = PREFIX + f.name;
                } else if (n instanceof MethodInsnNode mi && mi.owner.equals(from.name)) {
                    mi.owner = to.name;
                    mi.name = PREFIX + mi.name;
                } else if (n instanceof LdcInsnNode l && l.cst instanceof Type t && t.getInternalName().equals(from.name)) {
                    l.cst = Type.getObjectType(to.name);
                }
            }
            m.localVariables = null; // debug info only
            to.methods.add(m);
        }
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
