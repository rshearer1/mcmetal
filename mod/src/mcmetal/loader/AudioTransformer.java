package mcmetal.loader;

import java.util.Set;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Moves Minecraft's "is the audio device still there?" check off the render thread (on by default,
 * MCMETAL_AUDIO_ASYNC=0 turns it off). The sound engine calls Library.isCurrentDeviceDisconnected() every tick on
 * the render thread, and with Simple Voice Chat in the pack that OpenAL call sometimes blocked for 20-30 s (M3 run
 * J2, Hearth & Hex mods). mcmetal.loader.audio.AudioHooks is copied into Library, Library becomes a Runnable whose
 * run() does the real check on a daemon thread, and the OpenAL call inside isCurrentDeviceDisconnected() is swapped
 * for one that returns the last answer (the method's own "does this device support the check" test stays). Only
 * Minecraft's Library changes, in memory as it loads; no mod's jar is touched.
 */
final class AudioTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "com.mojang.blaze3d.audio.Library";
    static final String HOOKS = "mcmetal/loader/audio/AudioHooks";
    static final String PREFIX = GpuCullTransformer.PREFIX;

    static boolean wanted() {
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(System.getenv("MCMETAL_AUDIO_ASYNC"));
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        MethodInsnNode call = null; // ALC11/ALC10.alcGetInteger(device, ALC_CONNECTED) inside isCurrentDeviceDisconnected()
        for (MethodNode m : c.methods)
            if (m.name.equals("isCurrentDeviceDisconnected") && m.desc.equals("()Z"))
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKESTATIC && mi.name.equals("alcGetInteger")
                            && mi.desc.equals("(JI)I") && mi.owner.startsWith("org/lwjgl/openal/ALC"))
                        call = mi;
        boolean hasRun = c.methods.stream().anyMatch(m -> m.name.equals("run") && m.desc.equals("()V"));
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied: AudioHooks must not have one
        if (call == null || hasRun || c.interfaces.contains("java/lang/Runnable") || hooks == null) {
            MetalBootstrap.log("audio: Minecraft's sound Library is not the expected one, device check left on the render thread");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        // public void run() { mcmetal$check(); }
        c.interfaces.add("java/lang/Runnable");
        MethodNode run = new MethodNode(Opcodes.ACC_PUBLIC, "run", "()V", null, null);
        run.instructions.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "check", "()V", false));
        run.instructions.add(new InsnNode(Opcodes.RETURN));
        run.maxStack = 0;
        run.maxLocals = 1;
        c.methods.add(run);
        // alcGetInteger(device, what)  ->  mcmetal$connected(device, what, this)
        MethodNode owner = null;
        for (MethodNode m : c.methods)
            if (m.instructions.contains(call))
                owner = m;
        owner.instructions.insertBefore(call, new VarInsnNode(Opcodes.ALOAD, 0));
        call.owner = c.name;
        call.name = PREFIX + "connected";
        call.desc = "(JILjava/lang/Object;)I";
        owner.maxStack += 1;
        MetalBootstrap.log("audio: the device check runs off the render thread (MCMETAL_AUDIO_ASYNC)");
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
