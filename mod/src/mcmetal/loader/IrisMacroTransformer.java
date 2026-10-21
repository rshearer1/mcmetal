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

/**
 * Stops Iris telling shader packs they run on a Mac while mcmetal is the OpenGL.
 *
 * Iris defines MC_OS_MAC for packs to work around Apple's OpenGL 4.1, and Complementary then forces its coloured
 * light (ACT) off and shows an "not supported on Apple devices" screen. Iris resolves these defines in Java, so
 * mcmetal can't hide them at glShaderSource; instead StandardMacros.getOsString() returns MC_OS_UNKNOWN when
 * mcmetal is active. Without mcmetal (or without Iris) nothing changes.
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
        return List.of(new OsString());
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
}
