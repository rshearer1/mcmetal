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
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Distant Horizons behind shader packs without DH support (SEUS PTGI), on unless MCMETAL_DH_COMPOSITE=0.
 *
 * Two classes change, in memory as they load (neither mod's jar, nor the shader pack, is touched):
 *  - DH's LodRenderer gets mcmetal.loader.dh.DhCaptureHooks, and dhCapture(params) just before DH would copy its
 *    LOD picture to Minecraft's screen (a copy Iris cancels whenever a pack is on): it notes DH's colour and depth
 *    textures and DH's projection for this frame.
 *  - DH's GlGenericObjectRenderer gets mcmetal.loader.dh.DhGenericHooks: DH's clouds are skipped while the composite
 *    below is on (the pack draws its own clouds); beacon beams stay.
 *  - Iris's IrisRenderingPipeline gets mcmetal.loader.iris.DhCompositeHooks, and dhAfterFinal() at the end of
 *    finalizeLevelRendering(), after the pack's final pass: where the pack drew only sky, DH's LODs are blended in,
 *    fading into the pack's sky with distance. It only draws while Iris reports the pack has no DH programs.
 * With the switch off, or without one of the two mods, the classes are left exactly as they are.
 */
final class DhCompositeTransformer implements ITransformer<ClassNode> {
    static final String LOD = "com.seibel.distanthorizons.core.render.renderer.LodRenderer";
    static final String IRIS = "net.irisshaders.iris.pipeline.IrisRenderingPipeline";
    static final String GENERIC = "com.seibel.distanthorizons.common.render.openGl.generic.GlGenericObjectRenderer";
    static final String GENERIC_HOOKS = "mcmetal/loader/dh/DhGenericHooks";
    static final String GENERIC_EVENT = "com/seibel/distanthorizons/api/methods/events/abstractEvents/DhApiBeforeGenericObjectRenderEvent";
    static final String CAPTURE_HOOKS = "mcmetal/loader/dh/DhCaptureHooks";
    static final String COMPOSITE_HOOKS = "mcmetal/loader/iris/DhCompositeHooks";
    static final String PARAMS = "com/seibel/distanthorizons/core/render/RenderParams";
    static final String APPLY_EVENT = "com/seibel/distanthorizons/api/methods/events/abstractEvents/DhApiBeforeApplyShaderRenderEvent";
    static final String PREFIX = GpuCullTransformer.PREFIX;

    static boolean wanted() {
        String on = System.getenv("MCMETAL_DH_COMPOSITE");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_DH_COMPOSITE");
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(on);
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        if (c.name.equals(LOD.replace('.', '/')))
            return lod(c);
        return c.name.equals(GENERIC.replace('.', '/')) ? generic(c) : iris(c);
    }

    private static ClassNode lod(ClassNode c) {
        // in renderTerrain(RenderParams, ...), the "before apply" event DH fires just before copying its picture to
        // Minecraft's screen (Iris cancels that copy whenever a pack is on): ldc DhApiBeforeApplyShaderRenderEvent
        AbstractInsnNode event = null;
        MethodNode in = null;
        int found = 0;
        for (MethodNode m : c.methods)
            for (AbstractInsnNode n : m.instructions.toArray())
                if (n instanceof LdcInsnNode l && l.cst instanceof Type t && t.getInternalName().equals(APPLY_EVENT)) {
                    event = n;
                    in = m;
                    found++;
                }
        ClassNode hooks = hooks(CAPTURE_HOOKS);
        if (found != 1 || (in.access & Opcodes.ACC_STATIC) != 0 || !in.desc.startsWith("(L" + PARAMS + ";") || hooks == null) {
            MetalBootstrap.log("Distant Horizons behind shader packs: DH's LodRenderer is not the expected one, off");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        InsnList capture = new InsnList();
        capture.add(new VarInsnNode(Opcodes.ALOAD, 1)); // renderParams
        capture.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "dhCapture", "(L" + PARAMS + ";)V", false));
        in.instructions.insertBefore(event, capture);
        in.maxStack = Math.max(in.maxStack, 1);
        MetalBootstrap.log("Distant Horizons behind shader packs: DH's LOD picture is kept for packs without DH support");
        return c;
    }

    private static ClassNode generic(ClassNode c) {
        // ldc DhApiBeforeGenericObjectRenderEvent; getstatic EVENT_PARAM; invokevirtual fireAllEvents -> Z
        MethodInsnNode fire = null;
        FieldInsnNode param = null;
        MethodNode in = null;
        int found = 0;
        for (MethodNode m : c.methods)
            for (AbstractInsnNode n : m.instructions.toArray())
                if (n instanceof LdcInsnNode l && l.cst instanceof Type t && t.getInternalName().equals(GENERIC_EVENT)
                        && n.getNext() instanceof FieldInsnNode f && f.getOpcode() == Opcodes.GETSTATIC
                        && f.getNext() instanceof MethodInsnNode mi && mi.name.equals("fireAllEvents") && mi.desc.endsWith(")Z")) {
                    fire = mi;
                    param = f;
                    in = m;
                    found++;
                }
        ClassNode hooks = hooks(GENERIC_HOOKS);
        if (found != 1 || hooks == null) {
            MetalBootstrap.log("Distant Horizons behind shader packs: DH's generic renderer is not the expected one, DH clouds stay on");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        InsnList skip = new InsnList();
        skip.add(new FieldInsnNode(Opcodes.GETSTATIC, param.owner, param.name, param.desc));
        skip.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "dhSkip", "(ZLjava/lang/Object;)Z", false));
        in.instructions.insert(fire, skip);
        in.maxStack += 1;
        return c;
    }

    private static ClassNode iris(ClassNode c) {
        MethodNode fin = null;
        for (MethodNode m : c.methods)
            if (m.name.equals("finalizeLevelRendering") && m.desc.equals("()V"))
                fin = m;
        ClassNode hooks = hooks(COMPOSITE_HOOKS);
        if (fin == null || hooks == null) {
            MetalBootstrap.log("Distant Horizons behind shader packs: Iris's pipeline is not the expected one, off");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        for (AbstractInsnNode n : fin.instructions.toArray())
            if (n.getOpcode() == Opcodes.RETURN)
                fin.instructions.insertBefore(n, new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "dhAfterFinal", "()V", false));
        fin.maxStack = Math.max(fin.maxStack, 1);
        MetalBootstrap.log("Distant Horizons behind shader packs: LODs are drawn behind packs without DH support (MCMETAL_DH_COMPOSITE)");
        return c;
    }

    /** The hook class, or null if it has a static initializer (that would not be copied). */
    private static ClassNode hooks(String name) {
        ClassNode h = GpuCullTransformer.readHooks(name);
        return h == null || h.methods.stream().anyMatch(m -> m.name.equals("<clinit>")) ? null : h;
    }

    @Override
    public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
        return TransformerVoteResult.YES;
    }

    @Override
    public Set<Target<ClassNode>> targets() {
        return Set.of(Target.targetClass(LOD), Target.targetClass(GENERIC), Target.targetClass(IRIS));
    }

    @Override
    public TargetType<ClassNode> getTargetType() {
        return TargetType.CLASS;
    }
}
