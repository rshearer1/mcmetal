package mcmetal.loader;

import java.util.List;
import java.util.Set;

import cpw.mods.modlauncher.api.IEnvironment;
import cpw.mods.modlauncher.api.ITransformationService;
import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Stops Iris telling shader packs they run on a Mac while mcmetal is the OpenGL.
 *
 * Iris defines MC_OS_MAC for packs to work around Apple's OpenGL 4.1, and Complementary then forces its coloured
 * light (ACT) off and shows an "not supported on Apple devices" screen. Iris resolves these defines in Java, so
 * mcmetal can't hide them at glShaderSource; instead StandardMacros.getOsString() returns MC_OS_UNKNOWN when
 * mcmetal is active. Packs also get MCMETAL_RT defined, so they can use mcm_trace (hardware ray tracing) under
 * #ifdef and fall back elsewhere. Without mcmetal (or without Iris) nothing changes.
 */
public final class IrisMacroTransformer implements ITransformationService {
    @Override
    public String name() {
        return "mcmetal";
    }

    @Override
    public void initialize(IEnvironment env) {
    }

    @Override
    public void onLoad(IEnvironment env, Set<String> others) {
    }

    @Override
    public List<? extends ITransformer<?>> transformers() {
        return List.of(new OsString(), new RtDefine(), new GpuCullTransformer(), new DhMacTransformer(),
                new AudioTransformer(), new BiomeTransformer(), new SoundPhysicsTransformer(),
                new ShadowEntityTransformer(), new LoadSpeedTransformer(), new MenuWorldTransformer(), new DhCompositeTransformer(),
                new LightListTransformer(), new DynLightTransformer());
    }

    static final class OsString implements ITransformer<MethodNode> {
        @Override
        public MethodNode transform(MethodNode m, ITransformerVotingContext ctx) {
            // MCMETAL_KEEP_MAC_FLAG=1: packs see a Mac as on Apple's OpenGL (same features), for like-for-like benchmarks
            if (!Boolean.getBoolean(MetalBootstrap.ACTIVE) || System.getenv("MCMETAL_KEEP_MAC_FLAG") != null)
                return m;
            // if (Boolean.getBoolean("mcmetal.active")) return "MC_OS_UNKNOWN";
            LabelNode original = new LabelNode();
            InsnList pre = new InsnList();
            pre.add(new LdcInsnNode(MetalBootstrap.ACTIVE));
            pre.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Boolean", "getBoolean", "(Ljava/lang/String;)Z"));
            pre.add(new JumpInsnNode(Opcodes.IFEQ, original));
            pre.add(new LdcInsnNode("MC_OS_UNKNOWN"));
            pre.add(new InsnNode(Opcodes.ARETURN));
            pre.add(original);
            pre.add(new FrameNode(Opcodes.F_SAME, 0, null, 0, null));
            m.instructions.insert(pre);
            MetalBootstrap.log("Iris will not tell shader packs this is a Mac (mcmetal is not limited like Apple's OpenGL 4.1)");
            return m;
        }

        @Override
        public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
            return TransformerVoteResult.YES;
        }

        @Override
        public Set<Target<MethodNode>> targets() {
            return Set.of(Target.targetMethod("net.irisshaders.iris.gl.shader.StandardMacros", "getOsString",
                    "()Ljava/lang/String;"));
        }

        @Override
        public TargetType<MethodNode> getTargetType() {
            return TargetType.METHOD;
        }
    }

    /** Adds "#define MCMETAL_RT 1" and "#define MCMETAL_LIGHTS 1" next to Iris's MC_OS_* define (the one-argument define() it is passed to). */
    static final class RtDefine implements ITransformer<MethodNode> {
        static final String PAIR = "net/irisshaders/iris/helpers/StringPair";

        @Override
        public MethodNode transform(MethodNode m, ITransformerVotingContext ctx) {
            if (!Boolean.getBoolean(MetalBootstrap.ACTIVE))
                return m;
            // if (name.startsWith("MC_OS_") && Boolean.getBoolean("mcmetal.active")) list.add(new StringPair("MCMETAL_RT", "1"));
            LabelNode skip = new LabelNode();
            InsnList pre = new InsnList();
            pre.add(new VarInsnNode(Opcodes.ALOAD, 1));
            pre.add(new LdcInsnNode("MC_OS_"));
            pre.add(new MethodInsnNode(Opcodes.INVOKEVIRTUAL, "java/lang/String", "startsWith", "(Ljava/lang/String;)Z"));
            pre.add(new JumpInsnNode(Opcodes.IFEQ, skip));
            pre.add(new LdcInsnNode(MetalBootstrap.ACTIVE));
            pre.add(new MethodInsnNode(Opcodes.INVOKESTATIC, "java/lang/Boolean", "getBoolean", "(Ljava/lang/String;)Z"));
            pre.add(new JumpInsnNode(Opcodes.IFEQ, skip));
            // MCMETAL_LIGHTS: mcm_lights_near exists; MCMETAL_RT_PBR: mcm_hit_emission exists
            for (String name : new String[] {"MCMETAL_RT", "MCMETAL_LIGHTS", "MCMETAL_RT_PBR"}) {
                pre.add(new VarInsnNode(Opcodes.ALOAD, 0));
                pre.add(new TypeInsnNode(Opcodes.NEW, PAIR));
                pre.add(new InsnNode(Opcodes.DUP));
                pre.add(new LdcInsnNode(name));
                pre.add(new LdcInsnNode("1"));
                pre.add(new MethodInsnNode(Opcodes.INVOKESPECIAL, PAIR, "<init>", "(Ljava/lang/String;Ljava/lang/String;)V"));
                pre.add(new MethodInsnNode(Opcodes.INVOKEINTERFACE, "java/util/List", "add", "(Ljava/lang/Object;)Z", true));
                pre.add(new InsnNode(Opcodes.POP));
            }
            pre.add(skip);
            pre.add(new FrameNode(Opcodes.F_SAME, 0, null, 0, null));
            m.instructions.insert(pre);
            m.maxStack = Math.max(m.maxStack, 5);
            MetalBootstrap.log("shader packs get MCMETAL_RT, MCMETAL_LIGHTS and MCMETAL_RT_PBR (hardware ray tracing through mcm_trace)");
            return m;
        }

        @Override
        public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
            return TransformerVoteResult.YES;
        }

        @Override
        public Set<Target<MethodNode>> targets() {
            return Set.of(Target.targetMethod("net.irisshaders.iris.gl.shader.StandardMacros", "define",
                    "(Ljava/util/List;Ljava/lang/String;)V"));
        }

        @Override
        public TargetType<MethodNode> getTargetType() {
            return TargetType.METHOD;
        }
    }
}
