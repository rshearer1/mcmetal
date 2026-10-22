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

/**
 * Lets Distant Horizons use its normal OpenGL 4.5 path while mcmetal is the OpenGL.
 *
 * On a Mac DH assumes Apple's OpenGL 4.1 and, whatever the driver says, (1) uploads LOD buffers with glBufferData
 * in 256 KB slices with a glFlush after each one (every flush used to end the render pass the game was drawing),
 * (2) gives every LOD buffer its own quad index buffer, and (3) turns off its "generic" objects (DH clouds,
 * beacon beams). Each of those spots compares EPlatform.get() with EPlatform.MACOS; here MACOS is swapped for
 * UNIX, which a Mac never is, so DH takes the path it takes everywhere else: buffer-storage uploads (mcmetal
 * reports GL 4.5 and ARB_buffer_storage), one shared index buffer, generic objects on. Only these four DH classes
 * change, in memory as they load; DH's jar is never touched. MCMETAL_DH_MAC_PATH=1 keeps DH's Mac path.
 */
final class DhMacTransformer implements ITransformer<ClassNode> {
    static final String PLATFORM = "com/seibel/distanthorizons/core/jar/EPlatform";
    static final String[] TARGETS = {
        "com.seibel.distanthorizons.common.render.openGl.glObject.GLProxy",                     // upload method
        "com.seibel.distanthorizons.common.render.openGl.glObject.buffer.GLBuffer",              // 256 KB slices + glFlush
        "com.seibel.distanthorizons.common.render.openGl.generic.GlGenericObjectRenderer",       // clouds, beacons
        "com.seibel.distanthorizons.core.wrapperInterfaces.render.AbstractDhRenderApiDefinition", // one index buffer
    };

    static boolean wanted() {
        String keep = System.getenv("MCMETAL_DH_MAC_PATH");
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && (keep == null || keep.isEmpty() || keep.equals("0"));
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        int n = 0;
        for (var m : c.methods)
            for (AbstractInsnNode i : m.instructions.toArray())
                if (i.getOpcode() == Opcodes.GETSTATIC && i instanceof FieldInsnNode f && f.owner.equals(PLATFORM)
                        && f.name.equals("MACOS")) {
                    f.name = "UNIX";
                    n++;
                }
        String simple = c.name.substring(c.name.lastIndexOf('/') + 1);
        MetalBootstrap.log(n > 0 ? "Distant Horizons " + simple + ": OpenGL 4.5 path instead of the Apple OpenGL one (" + n + " check"
                + (n == 1 ? "" : "s") + ")" : "Distant Horizons " + simple + " has no Mac check here any more, left as it is");
        return c;
    }

    @Override
    public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
        return TransformerVoteResult.YES;
    }

    @Override
    public Set<Target<ClassNode>> targets() {
        Set<Target<ClassNode>> t = new java.util.HashSet<>();
        for (String name : TARGETS)
            t.add(Target.targetClass(name));
        return t;
    }

    @Override
    public TargetType<ClassNode> getTargetType() {
        return TargetType.CLASS;
    }
}
