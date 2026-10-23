package mcmetal.loader;

import java.util.Set;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Moves Sound Physics Remastered's ray tracing off Minecraft's sound engine thread (on by default,
 * MCMETAL_SOUND_PHYSICS_ASYNC=0 turns it off; =1 turns it on even when the game isn't on Metal). Sound Physics traces
 * each new sound inside Channel.play() on that thread, and the render thread waits for the thread before every new
 * sound, so a tick with several new sounds held up the frame for all their rays (up to 20 ms in a Linux test).
 * mcmetal.loader.audio.SoundPhysicsHooks is copied into com.sonicether.soundphysics.SoundPhysics, onPlaySound() hands
 * the sound to a daemon thread (held silent until traced), and setEnvironment() reports which sound it finished.
 * Only that class changes, in memory as it loads; Sound Physics' jar is not touched. Without Sound Physics nothing
 * happens.
 */
final class SoundPhysicsTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "com.sonicether.soundphysics.SoundPhysics";
    static final String HOOKS = "mcmetal/loader/audio/SoundPhysicsHooks";
    static final String PREFIX = GpuCullTransformer.PREFIX;
    static final String PROCESS = "(IDDDLnet/minecraft/sounds/SoundSource;Lnet/minecraft/resources/ResourceLocation;Z)Lnet/minecraft/world/phys/Vec3;";

    static boolean wanted() {
        String on = System.getenv("MCMETAL_SOUND_PHYSICS_ASYNC");
        return "1".equals(on) || Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(on);
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        MethodNode onPlay = method(c, "onPlaySound", "(DDDI)V"), setEnv = method(c, "setEnvironment", "(IFFFFFFFFFF)V");
        boolean fields = c.fields.stream().filter(f -> (f.access & Opcodes.ACC_STATIC) != 0
                && (f.name.equals("lastSoundCategory") && f.desc.equals("Lnet/minecraft/sounds/SoundSource;")
                || f.name.equals("lastSound") && f.desc.equals("Lnet/minecraft/resources/ResourceLocation;")
                || f.name.equals("maxAuxSends") && f.desc.equals("I"))).count() == 3;
        boolean ctor = method(c, "<init>", "()V") != null;
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied: SoundPhysicsHooks must not have one
        if (onPlay == null || setEnv == null || method(c, "processSound", PROCESS) == null || !fields || !ctor
                || method(c, "run", "()V") != null || c.interfaces.contains("java/lang/Runnable") || hooks == null) {
            MetalBootstrap.log("sound physics: not the Sound Physics Remastered version expected, its rays stay on the sound engine thread");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        // public void run() { mcmetal$loop(); }
        c.interfaces.add("java/lang/Runnable");
        MethodNode run = new MethodNode(Opcodes.ACC_PUBLIC, "run", "()V", null, null);
        run.instructions.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "loop", "()V", false));
        run.instructions.add(new InsnNode(Opcodes.RETURN));
        run.maxStack = 0;
        run.maxLocals = 1;
        c.methods.add(run);
        // onPlaySound(x, y, z, source) { mcmetal$play(x, y, z, source); }
        InsnList body = new InsnList();
        body.add(new VarInsnNode(Opcodes.DLOAD, 0));
        body.add(new VarInsnNode(Opcodes.DLOAD, 2));
        body.add(new VarInsnNode(Opcodes.DLOAD, 4));
        body.add(new VarInsnNode(Opcodes.ILOAD, 6));
        body.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "play", "(DDDI)V", false));
        body.add(new InsnNode(Opcodes.RETURN));
        onPlay.instructions = body;
        onPlay.tryCatchBlocks.clear();
        onPlay.localVariables = null;
        onPlay.maxStack = 7;
        onPlay.maxLocals = 7;
        // setEnvironment(source, ...) { mcmetal$applied(source); ...as before }
        InsnList head = new InsnList();
        head.add(new VarInsnNode(Opcodes.ILOAD, 0));
        head.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "applied", "(I)V", false));
        setEnv.instructions.insert(head);
        setEnv.maxStack = Math.max(setEnv.maxStack, 1);
        MetalBootstrap.log("sound physics: Sound Physics Remastered traces its rays on its own thread (MCMETAL_SOUND_PHYSICS_ASYNC)");
        return c;
    }

    private static MethodNode method(ClassNode c, String name, String desc) {
        for (MethodNode m : c.methods)
            if (m.name.equals(name) && m.desc.equals(desc))
                return m;
        return null;
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
