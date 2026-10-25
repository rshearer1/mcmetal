package mcmetal.loader;

import java.util.Set;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.LineNumberNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * The menu world cache (on by default, MCMETAL_MENU_CACHE=0 turns it off): while an inventory-style menu is open, the
 * world behind it is drawn only MCMETAL_MENU_WORLD_FPS times a second and reused in between (see
 * mcmetal.loader.menu.MenuHooks, copied into GameRenderer). In GameRenderer.render() the world block
 *   renderLevel(dt); tryTakeScreenshotIfNeeded(); levelRenderer.doEntityOutline(); [post effect]
 *   minecraft.getMainRenderTarget().bindWrite(true);
 * becomes
 *   if (!mcmetal$skipWorld()) { renderLevel(dt); ...; [post effect] }
 *   mcmetal$afterWorld(); minecraft.getMainRenderTarget().bindWrite(true);
 * Only Minecraft's GameRenderer changes, in memory as it loads; with the switch off it is left exactly as it is.
 */
final class MenuWorldTransformer implements ITransformer<ClassNode> {
    static final String TARGET = "net.minecraft.client.renderer.GameRenderer";
    static final String HOOKS = "mcmetal/loader/menu/MenuHooks";
    static final String PREFIX = GpuCullTransformer.PREFIX;

    static boolean wanted() {
        String on = System.getenv("MCMETAL_MENU_CACHE");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_MENU_CACHE");
        return Boolean.getBoolean(MetalBootstrap.ACTIVE) && !"0".equals(on);
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        MethodNode render = null;
        for (MethodNode m : c.methods)
            if (m.name.equals("render") && m.desc.equals("(Lnet/minecraft/client/DeltaTracker;Z)V"))
                render = m;
        // the world block must still be vanilla's: aload 0, aload 1, renderLevel(dt) ... label: aload 0,
        // getfield minecraft, getMainRenderTarget(), iconst_1, bindWrite(Z), with nothing stored in between
        AbstractInsnNode call = null, end = null;
        if (render != null)
            for (AbstractInsnNode n : render.instructions.toArray()) {
                if (call == null && n instanceof MethodInsnNode mi && mi.owner.equals(c.name) && mi.name.equals("renderLevel")
                        && mi.desc.equals("(Lnet/minecraft/client/DeltaTracker;)V"))
                    call = n;
                else if (call != null && n instanceof MethodInsnNode mi && mi.name.equals("bindWrite")
                        && mi.owner.equals("com/mojang/blaze3d/pipeline/RenderTarget") && mi.desc.equals("(Z)V")) {
                    end = n;
                    break;
                } else if (call != null && n instanceof VarInsnNode v && v.getOpcode() >= Opcodes.ISTORE) {
                    break; // a new local in the block: the jump below would not match its frames
                }
            }
        AbstractInsnNode a1 = real(call, -1), a0 = real(a1, -1);
        AbstractInsnNode b1 = real(end, -1), b2 = real(b1, -1), b3 = real(b2, -1), b4 = real(b3, -1);
        LabelNode resume = null;
        for (AbstractInsnNode n = b4 == null ? null : b4.getPrevious(); n != null; n = n.getPrevious()) {
            if (n instanceof LabelNode l) {
                resume = l;
                break;
            }
            if (!(n instanceof LineNumberNode || n instanceof FrameNode))
                break;
        }
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied: MenuHooks must not have one
        if (end == null || !load(a1, 1) || !load(a0, 0) || b1 == null || b1.getOpcode() != Opcodes.ICONST_1
                || !(b2 instanceof MethodInsnNode m2 && m2.name.equals("getMainRenderTarget"))
                || b3 == null || b3.getOpcode() != Opcodes.GETFIELD || !load(b4, 0) || resume == null || hooks == null) {
            MetalBootstrap.log("menu world cache: Minecraft's GameRenderer is not the expected one, menus draw the world every frame");
            return c;
        }
        GpuCullTransformer.merge(hooks, c);
        InsnList skip = new InsnList();
        skip.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "skipWorld", "()Z", false));
        skip.add(new JumpInsnNode(Opcodes.IFNE, resume));
        render.instructions.insertBefore(a0, skip);
        AbstractInsnNode at = resume;
        while (at.getNext() instanceof FrameNode || at.getNext() instanceof LineNumberNode)
            at = at.getNext(); // after the label's frame: both paths arrive here
        render.instructions.insert(at, new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "afterWorld", "()V", false));
        render.maxStack = Math.max(render.maxStack, 1);
        MetalBootstrap.log("menu world cache: the world behind an open menu is reused between redraws (MCMETAL_MENU_CACHE)");
        return c;
    }

    /** The nearest real instruction before (dir -1) n, skipping labels, line numbers and frames. */
    private static AbstractInsnNode real(AbstractInsnNode n, int dir) {
        if (n == null)
            return null;
        n = n.getPrevious();
        while (n != null && n.getOpcode() < 0)
            n = n.getPrevious();
        return n;
    }

    private static boolean load(AbstractInsnNode n, int var) {
        return n instanceof VarInsnNode v && v.getOpcode() == Opcodes.ALOAD && v.var == var;
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
