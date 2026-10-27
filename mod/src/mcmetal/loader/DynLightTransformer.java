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
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Dynamic lights on the GPU (MCMETAL_DYN_LIGHTS=0 turns it off). LambDynamicLights lights the world around a held
 * torch or a burning mob by rebuilding the chunk meshes near it with extra block light, every tick the light moves a
 * tenth of a block: about 8 sections a tick per moving light, plus the 8 it left. With the patches here Sodium's
 * terrain vertex shader adds that light itself from a list of up to 32 lights handed over each frame (LambDynamicLights'
 * own falloff, so it looks the same), and LambDynamicLights stops asking for rebuilds and leaves its light out of chunk
 * meshes. Mobs, chests and particles near a light are lit by LambDynamicLights as before.
 *
 * Only without a shader pack: Iris draws terrain with the pack's own programs, so with a pack in use everything works
 * the old way (and packs light the held item themselves). Beacon beams and guardian lasers (LambDynamicLights' line
 * lights, off unless turned on in its settings) don't light terrain on this path.
 *
 *   ShaderLoader          loadShader() passes each source through DynLightShaderHooks.shaderSource()
 *   DefaultChunkRenderer  render() calls DynLightHooks.lights() once the pass's program is bound
 *   LambDynLights         gets LdlHooks (the frame's light list, the gpu flag); getLightmapWithDynamicLight() returns
 *                         the world's own light while the flag is set, except for the ClientLevel (mobs, block entities)
 *   ChunkRebuildScheduler update() and remove() do nothing while the flag is set
 * Without LambDynamicLights only the shader gets its (unused) light list. The jars are never changed.
 */
final class DynLightTransformer implements ITransformer<ClassNode> {
    static final String LOADER = "net.caffeinemc.mods.sodium.client.gl.shader.ShaderLoader";
    static final String LDL = "dev.lambdaurora.lambdynlights.LambDynLights";
    static final String SCHEDULER = "dev.lambdaurora.lambdynlights.engine.scheduler.ChunkRebuildScheduler";
    static final String PREFIX = GpuCullTransformer.PREFIX;
    static final String LDL_NAME = LDL.replace('.', '/');

    static boolean wanted() {
        String on = System.getenv("MCMETAL_DYN_LIGHTS");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_DYN_LIGHTS");
        // MCMETAL_DYN_LIGHTS=1 also without mcmetal's OpenGL (the Linux test rig on Mesa: it's all Java and GLSL)
        return "1".equals(on) || (Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(on));
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        switch (c.name.replace('/', '.')) {
            case LOADER -> loader(c);
            case GpuCullTransformer.TARGET -> renderer(c);
            case LDL -> ldl(c);
            case SCHEDULER -> scheduler(c);
            default -> {
            }
        }
        return c;
    }

    private static void loader(ClassNode c) {
        MethodNode load = method(c, "loadShader", null);
        ClassNode hooks = hooks("mcmetal/loader/sodium/DynLightShaderHooks");
        MethodInsnNode get = null;
        if (load != null)
            for (AbstractInsnNode n : load.instructions.toArray())
                if (n instanceof MethodInsnNode mi && mi.owner.equals(c.name) && mi.name.equals("getShaderSource"))
                    get = mi;
        if (get == null || hooks == null) {
            MetalBootstrap.log("dynamic lights: Sodium's ShaderLoader is not the expected one, lights stay on the CPU");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        InsnList call = new InsnList(); // source on the stack -> shaderSource(source, id)
        call.add(new VarInsnNode(Opcodes.ALOAD, 1));
        call.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "shaderSource",
                "(Ljava/lang/String;Lnet/minecraft/resources/ResourceLocation;)Ljava/lang/String;", false));
        load.instructions.insert(get, call);
        load.maxStack = Math.max(load.maxStack, 2);
    }

    private static void renderer(ClassNode c) {
        MethodNode render = method(c, "render", GpuCullTransformer.RENDER_DESC);
        ClassNode hooks = hooks("mcmetal/loader/sodium/DynLightHooks");
        MethodInsnNode begin = null;
        if (render != null)
            for (AbstractInsnNode n : render.instructions.toArray())
                if (begin == null && n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKESPECIAL && mi.name.equals("begin"))
                    begin = mi;
        if (begin == null || hooks == null) {
            MetalBootstrap.log("dynamic lights: Sodium's DefaultChunkRenderer is not the expected one, lights stay on the CPU");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        InsnList call = new InsnList(); // lights(this, camera)
        call.add(new VarInsnNode(Opcodes.ALOAD, 0));
        call.add(new VarInsnNode(Opcodes.ALOAD, 5));
        call.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "lights",
                "(L" + c.name + ";Lnet/caffeinemc/mods/sodium/client/render/viewport/CameraTransform;)V", false));
        render.instructions.insert(begin, call);
        render.maxStack = Math.max(render.maxStack, 2);
    }

    private static void ldl(ClassNode c) {
        MethodNode light = method(c, "getLightmapWithDynamicLight",
                "(Lnet/minecraft/world/level/BlockAndTintGetter;Lnet/minecraft/core/BlockPos;I)I");
        ClassNode hooks = hooks("mcmetal/loader/ldl/LdlHooks");
        if (light == null || hooks == null) {
            MetalBootstrap.log("dynamic lights: LambDynamicLights is not the expected version, it keeps its own way");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        // if (mcmetal$gpu && !(level instanceof ClientLevel)) return lightmap;
        LabelNode original = new LabelNode();
        InsnList pre = new InsnList();
        pre.add(new FieldInsnNode(Opcodes.GETSTATIC, c.name, PREFIX + "gpu", "Z"));
        pre.add(new JumpInsnNode(Opcodes.IFEQ, original));
        pre.add(new VarInsnNode(Opcodes.ALOAD, 1));
        pre.add(new TypeInsnNode(Opcodes.INSTANCEOF, "net/minecraft/client/multiplayer/ClientLevel"));
        pre.add(new JumpInsnNode(Opcodes.IFNE, original));
        pre.add(new VarInsnNode(Opcodes.ILOAD, 3));
        pre.add(new InsnNode(Opcodes.IRETURN));
        pre.add(original);
        pre.add(new FrameNode(Opcodes.F_SAME, 0, null, 0, null));
        light.instructions.insert(pre);
        light.maxStack = Math.max(light.maxStack, 1);
        System.setProperty("mcmetal.dynlights.ldl", "true"); // DynLightShaderHooks: worth adding the light list
        MetalBootstrap.log("dynamic lights: LambDynamicLights' lights go to Sodium's terrain shader when no shader pack is"
                + " in use, instead of chunk rebuilds (MCMETAL_DYN_LIGHTS)");
    }

    private static void scheduler(ClassNode c) {
        int hooked = 0;
        for (MethodNode m : c.methods) {
            boolean update = m.name.equals("update") && m.desc.startsWith("(Ldev/lambdaurora/lambdynlights/engine/source/DynamicLightSource;Lit/unimi/dsi/fastutil/longs/Long2ObjectMap;)");
            boolean remove = m.name.equals("remove") && m.desc.equals("(Ldev/lambdaurora/lambdynlights/engine/source/DynamicLightSource;)V");
            if ((!update && !remove) || (m.access & Opcodes.ACC_ABSTRACT) != 0)
                continue;
            // if (LambDynLights.mcmetal$gpu) return;
            LabelNode original = new LabelNode();
            InsnList pre = new InsnList();
            pre.add(new FieldInsnNode(Opcodes.GETSTATIC, LDL_NAME, PREFIX + "gpu", "Z"));
            pre.add(new JumpInsnNode(Opcodes.IFEQ, original));
            pre.add(new InsnNode(Opcodes.RETURN));
            pre.add(original);
            pre.add(new FrameNode(Opcodes.F_SAME, 0, null, 0, null));
            m.instructions.insert(pre);
            m.maxStack = Math.max(m.maxStack, 1);
            hooked++;
        }
        if (hooked != 2)
            MetalBootstrap.log("dynamic lights: LambDynamicLights' ChunkRebuildScheduler is not the expected one (" + hooked
                    + " of 2 methods), rebuilds may still be asked for");
    }

    private static MethodNode method(ClassNode c, String name, String desc) {
        for (MethodNode m : c.methods)
            if (m.name.equals(name) && (desc == null || m.desc.equals(desc)))
                return m;
        return null;
    }

    private static ClassNode hooks(String name) {
        ClassNode hooks = GpuCullTransformer.readHooks(name);
        return hooks == null || hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")) ? null : hooks;
    }

    @Override
    public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
        return TransformerVoteResult.YES;
    }

    @Override
    public Set<Target<ClassNode>> targets() {
        return Set.of(Target.targetClass(LOADER), Target.targetClass(GpuCullTransformer.TARGET), Target.targetClass(LDL),
                Target.targetClass(SCHEDULER));
    }

    @Override
    public TargetType<ClassNode> getTargetType() {
        return TargetType.CLASS;
    }
}
