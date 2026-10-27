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
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * The HUD cache (on by default, MCMETAL_HUD_CACHE=0 turns it off): the HUD layers after the crosshair are drawn
 * MCMETAL_HUD_FPS times a second into a texture that is laid over the world every frame (see
 * mcmetal.loader.hud.HudHooks, copied into NeoForge's GuiLayerManager). In GuiLayerManager.renderInner()
 *   for (NamedLayer layer : layers) { [Pre event] if (!canceled) { layer.layer().render(g, dt); [Post event] } translate }
 * becomes
 *   mcmetal$start(layers, g);
 *   for (NamedLayer layer : layers) { if (!mcmetal$skip(layer, g)) { [Pre event] ... } translate }
 *   mcmetal$end(g);
 * Only GuiLayerManager changes, in memory as it loads; with the switch off it is left exactly as it is.
 */
final class HudCacheTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "net.neoforged.neoforge.client.gui.GuiLayerManager";
    static final String HOOKS = "mcmetal/loader/hud/HudHooks";
    static final String PREFIX = GpuCullTransformer.PREFIX;
    static final String NAMED = "net/neoforged/neoforge/client/gui/GuiLayerManager$NamedLayer";
    static final String GRAPHICS = "Lnet/minecraft/client/gui/GuiGraphics;";

    static boolean wanted() {
        String on = System.getenv("MCMETAL_HUD_CACHE");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_HUD_CACHE");
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(on);
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        MethodNode inner = null;
        for (MethodNode m : c.methods)
            if (m.name.equals("renderInner") && m.desc.equals("(" + GRAPHICS + "Lnet/minecraft/client/DeltaTracker;)V"))
                inner = m;
        // the loop must still be NeoForge's: checkcast NamedLayer, astore n, ..., isCanceled(), ifne <after the layer>
        VarInsnNode store = null;
        LabelNode after = null;
        boolean fieldOk = false;
        if (inner != null)
            for (AbstractInsnNode n : inner.instructions.toArray()) {
                if (n instanceof FieldInsnNode f && f.owner.equals(c.name) && f.name.equals("layers") && f.desc.equals("Ljava/util/List;"))
                    fieldOk = true;
                else if (store == null && n instanceof TypeInsnNode t && t.getOpcode() == Opcodes.CHECKCAST && t.desc.equals(NAMED)
                        && t.getNext() instanceof VarInsnNode v && v.getOpcode() == Opcodes.ASTORE)
                    store = v;
                else if (store != null && after == null && n instanceof MethodInsnNode mi && mi.name.equals("isCanceled")
                        && mi.getNext() instanceof JumpInsnNode j && j.getOpcode() == Opcodes.IFNE)
                    after = j.label;
            }
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied: HudHooks must not have one
        if (!fieldOk || store == null || after == null || hooks == null) {
            MetalBootstrap.log("HUD cache: NeoForge's GuiLayerManager is not the expected one, the HUD is drawn every frame");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        InsnList head = new InsnList();
        head.add(new VarInsnNode(Opcodes.ALOAD, 0));
        head.add(new FieldInsnNode(Opcodes.GETFIELD, c.name, "layers", "Ljava/util/List;"));
        head.add(new VarInsnNode(Opcodes.ALOAD, 1));
        head.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "start", "(Ljava/util/List;" + GRAPHICS + ")V", false));
        inner.instructions.insert(head);
        InsnList skip = new InsnList();
        skip.add(new VarInsnNode(Opcodes.ALOAD, store.var));
        skip.add(new VarInsnNode(Opcodes.ALOAD, 1));
        skip.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "skip", "(Ljava/lang/Object;" + GRAPHICS + ")Z", false));
        skip.add(new JumpInsnNode(Opcodes.IFNE, after)); // same locals as the event's own jump there
        inner.instructions.insert(store, skip);
        for (AbstractInsnNode n : inner.instructions.toArray())
            if (n.getOpcode() == Opcodes.RETURN) {
                InsnList end = new InsnList();
                end.add(new VarInsnNode(Opcodes.ALOAD, 1));
                end.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "end", "(" + GRAPHICS + ")V", false));
                inner.instructions.insertBefore(n, end);
            }
        inner.maxStack = Math.max(inner.maxStack, 3);
        MetalBootstrap.log("HUD cache: the HUD after the crosshair is redrawn a few times a second and reused in between (MCMETAL_HUD_CACHE)");
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
