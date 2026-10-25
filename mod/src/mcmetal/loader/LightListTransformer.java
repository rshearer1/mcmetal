package mcmetal.loader;

import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.Set;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.FieldNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * One light list for every shader pack (mcmetal/lights.tsv in this jar), on unless MCMETAL_LIGHT_LIST=0. Also on
 * Apple's OpenGL: it only changes which block ids Iris hands the pack.
 *
 * Iris's IdMap gets mcmetal.loader.iris.LightListHooks, and addLights(blockPropertiesMap) at the end of its
 * constructor: every listed light the pack doesn't name gets the id of a vanilla twin the pack does name (see
 * LightListHooks). The pack's files are not touched. The list and the twins travel to the hook as system properties,
 * since the game's class loader can't see this jar's resources.
 */
final class LightListTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "net.irisshaders.iris.shaderpack.IdMap";
    static final String HOOKS = "mcmetal/loader/iris/LightListHooks";
    static final String FIELD = "blockPropertiesMap";
    static final String PREFIX = GpuCullTransformer.PREFIX;

    static boolean wanted() {
        String on = System.getenv("MCMETAL_LIGHT_LIST");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_LIGHT_LIST");
        return !"0".equals(on);
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        FieldNode field = null;
        for (FieldNode f : c.fields)
            if (f.name.equals(FIELD) && (f.access & Opcodes.ACC_STATIC) == 0)
                field = f;
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        String list = resource("/mcmetal/lights.tsv"), twins = resource("/mcmetal/light-twins.tsv");
        if (field == null || hooks == null || hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>"))
                || list == null || twins == null) {
            MetalBootstrap.log("light list: Iris's IdMap is not the expected one (or the list is missing), off");
            return c;
        }
        System.setProperty("mcmetal.lights.list", list);
        System.setProperty("mcmetal.lights.twins", twins);
        GpuCullTransformer.merge(hooks, c);
        int hooked = 0;
        for (MethodNode m : c.methods) {
            if (!m.name.equals("<init>"))
                continue;
            for (AbstractInsnNode n : m.instructions.toArray())
                if (n.getOpcode() == Opcodes.RETURN) {
                    InsnList call = new InsnList();
                    call.add(new VarInsnNode(Opcodes.ALOAD, 0));
                    call.add(new FieldInsnNode(Opcodes.GETFIELD, c.name, field.name, field.desc));
                    call.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "addLights", "(Ljava/util/Map;)V", false));
                    m.instructions.insertBefore(n, call);
                    hooked++;
                }
            m.maxStack = Math.max(m.maxStack, 2);
        }
        MetalBootstrap.log("light list: shader packs get ids for the lights they don't name (" + hooked
                + " constructor exits, MCMETAL_LIGHT_LIST)");
        return c;
    }

    private static String resource(String name) {
        try (InputStream in = LightListTransformer.class.getResourceAsStream(name)) {
            return in == null ? null : new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            return null;
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
