package mcmetal.loader;

import java.io.IOException;
import java.io.InputStream;
import java.util.Base64;
import java.util.Set;
import java.util.TreeSet;

import cpw.mods.modlauncher.api.ITransformer;
import cpw.mods.modlauncher.api.ITransformerVotingContext;
import cpw.mods.modlauncher.api.TargetType;
import cpw.mods.modlauncher.api.TransformerVoteResult;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.commons.ClassRemapper;
import org.objectweb.asm.commons.SimpleRemapper;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldNode;
import org.objectweb.asm.tree.FrameNode;
import org.objectweb.asm.tree.InsnList;
import org.objectweb.asm.tree.InsnNode;
import org.objectweb.asm.tree.JumpInsnNode;
import org.objectweb.asm.tree.LabelNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * JEI's start after joining a world, with recipe registration and the ingredient list built on a background thread
 * (opt-in: MCMETAL_ASYNC_JEI=1 in the environment or mcmetal/options.txt; without it nothing here touches JEI). Idea
 * from Nitro (MIT, github.com/TinsleyDevers/Nitro, fix 14), our own code: see load/jei/AsyncJeiStart for the steps.
 *
 * JeiStarter: its fields and verifyClientRecipes() become public, JeiStartHooks is merged in, start() begins with
 * "if (mcmetal$async(this)) return;" and stop() with "mcmetal$stopped();". AsyncJeiStart's class file is renamed into
 * JEI's package and handed over as Base64 in mcmetal$asyncBytes(), so it is defined next to JeiStarter at run time.
 * Only for a JeiStarter whose start() calls exactly the JEI methods AsyncJeiStart was written from (JEI 19.x);
 * anything else is left alone with a log line.
 * ErrorUtil: assertMainThread() also lets AsyncJeiStart's thread through (load/jei/JeiThreadHooks).
 */
final class JeiStartTransformer implements ITransformer<ClassNode> {
    static final String STARTER = "mezz.jei.library.startup.JeiStarter";
    static final String ERRORS = "mezz.jei.common.util.ErrorUtil";
    static final String HOOKS = "mcmetal/loader/load/jei/JeiStartHooks";
    static final String THREAD_HOOKS = "mcmetal/loader/load/jei/JeiThreadHooks";
    static final String ASYNC = "mcmetal/loader/load/jei/AsyncJeiStart";
    static final String ASYNC_AS = "mezz/jei/library/startup/McmetalAsyncJei";
    static final String PREFIX = GpuCullTransformer.PREFIX;
    static final String MC = "net/minecraft/client/Minecraft";
    /** Fields of JeiStarter that AsyncJeiStart reads, with their types. */
    static final String[][] FIELDS = {
            {"data", "Lmezz/jei/library/startup/StartData;"}, {"plugins", "Ljava/util/List;"},
            {"vanillaPlugin", "Lmezz/jei/library/plugins/vanilla/VanillaPlugin;"},
            {"modIdFormatConfig", "Lmezz/jei/library/config/ModIdFormatConfig;"},
            {"colorNameConfig", "Lmezz/jei/library/config/ColorNameConfig;"},
            {"recipeCategorySortingConfig", "Lmezz/jei/library/config/RecipeCategorySortingConfig;"},
            {"configManager", "Lmezz/jei/common/config/ConfigManager;"},
            {"jeiClientConfigs", "Lmezz/jei/common/config/JeiClientConfigs;"},
            {"stopCallbacks", "Ljava/util/List;"}, {"running", "Z"}};
    /** The JEI methods JeiStarter.start() calls in JEI 19.51 (owner.name, from mezz/jei only). */
    static final Set<String> START_CALLS = Set.of("PluginCaller.callOnPlugins", "PluginLoader.createGuiScreenHelper",
            "PluginLoader.createJeiHelpers", "PluginLoader.createRecipeManager", "PluginLoader.createRecipeTransferManager",
            "PluginLoader.createSearchStorageFactory", "PluginLoader.registerIngredients", "PluginLoader.registerModAliases",
            "PluginLoader.registerSubtypes", "Internal.getKeyMappings", "Internal.hasClientRecipes", "Internal.setClientFallbackRecipes",
            "Internal.setRuntime", "RegistryUtil.setRegistryAccess", "VanillaClientRecipeLoader.getVanillaRecipes",
            "LoggedTimer.<init>", "LoggedTimer.start", "LoggedTimer.stop", "ConfigManager.onJeiStarted",
            "JeiClientConfigs.getIngredientFilterConfig", "ColorHelper.<init>", "FocusFactory.<init>", "CodecHelper.<init>",
            "IPlatformHelper.getConfigHelper", "IPlatformConfigHelper.createJeiConfigDir", "EditModeConfig$FileSerializer.<init>",
            "EditModeConfig.<init>", "StartData.serverConnection", "RuntimeRegistration.<init>",
            "RuntimeRegistration.getIngredientListOverlay", "RuntimeRegistration.getBookmarkOverlay",
            "RuntimeRegistration.getRecipesGui", "RuntimeRegistration.getIngredientFilter", "JeiRuntime.<init>",
            "JeiStarter.verifyClientRecipes");

    static boolean wanted() {
        String on = System.getenv("MCMETAL_ASYNC_JEI");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_ASYNC_JEI"); // mcmetal/options.txt
        return on != null && on.trim().equals("1");
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        if (c.name.equals(STARTER.replace('.', '/')))
            starter(c);
        else if (c.name.equals(ERRORS.replace('.', '/')))
            errors(c);
        return c;
    }

    static void starter(ClassNode c) {
        MethodNode start = null, stop = null, verify = null;
        for (MethodNode m : c.methods) {
            if (m.name.equals("start") && m.desc.equals("()V"))
                start = m;
            if (m.name.equals("stop") && m.desc.equals("()V"))
                stop = m;
            if (m.name.equals("verifyClientRecipes") && m.desc.equals("(L" + MC + ";)V"))
                verify = m;
        }
        Set<String> calls = new TreeSet<>();
        if (start != null)
            for (AbstractInsnNode n : start.instructions.toArray())
                if (n instanceof MethodInsnNode mi && mi.owner.startsWith("mezz/jei/"))
                    calls.add(mi.owner.substring(mi.owner.lastIndexOf('/') + 1) + "." + mi.name);
        int fields = 0;
        for (FieldNode f : c.fields)
            for (String[] want : FIELDS)
                if (f.name.equals(want[0]) && f.desc.equals(want[1]) && (f.access & Opcodes.ACC_STATIC) == 0)
                    fields++;
        ClassNode hooks = GpuCullTransformer.readHooks(HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        String async = hooks == null ? null : asyncClass();
        if (start == null || stop == null || verify == null || !calls.equals(START_CALLS) || fields != FIELDS.length
                || hooks == null || async == null) {
            MetalBootstrap.log("JEI start: JEI is not the version the background start was written for ("
                    + (calls.equals(START_CALLS) ? "fields" : "calls") + " differ), it starts the usual way");
            return;
        }
        for (FieldNode f : c.fields)
            for (String[] want : FIELDS)
                if (f.name.equals(want[0]))
                    f.access = f.access & ~(Opcodes.ACC_PRIVATE | Opcodes.ACC_PROTECTED) | Opcodes.ACC_PUBLIC;
        verify.access = verify.access & ~(Opcodes.ACC_PRIVATE | Opcodes.ACC_PROTECTED) | Opcodes.ACC_PUBLIC;
        GpuCullTransformer.merge(hooks, c);
        for (MethodNode m : c.methods)
            if (m.name.equals(PREFIX + "asyncBytes")) { // return "<part 1>".concat("<part 2>")...
                InsnList body = new InsnList();
                int parts = 0;
                for (int i = 0; i < async.length(); i += 60000, parts++) {
                    body.add(new LdcInsnNode(async.substring(i, Math.min(async.length(), i + 60000))));
                    if (parts > 0)
                        body.add(new MethodInsnNode(Opcodes.INVOKEVIRTUAL, "java/lang/String", "concat",
                                "(Ljava/lang/String;)Ljava/lang/String;", false));
                }
                body.add(new InsnNode(Opcodes.ARETURN));
                m.instructions = body;
                m.tryCatchBlocks.clear();
                m.maxStack = 2;
                m.maxLocals = 0;
            }
        // start(): if (mcmetal$async(this)) return;
        LabelNode usual = new LabelNode();
        InsnList pre = new InsnList();
        pre.add(new VarInsnNode(Opcodes.ALOAD, 0));
        pre.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "async", "(L" + c.name + ";)Z", false));
        pre.add(new JumpInsnNode(Opcodes.IFEQ, usual));
        pre.add(new InsnNode(Opcodes.RETURN));
        pre.add(usual);
        pre.add(new FrameNode(Opcodes.F_SAME, 0, null, 0, null));
        start.instructions.insert(pre);
        start.maxStack = Math.max(start.maxStack, 1);
        stop.instructions.insert(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "stopped", "()V", false));
        MetalBootstrap.log("JEI start: recipes and the ingredient list are built on a background thread (MCMETAL_ASYNC_JEI)");
    }

    /** AsyncJeiStart's class file, renamed into JEI's package, in Base64; null if it can't be read. */
    static String asyncClass() {
        try (InputStream in = JeiStartTransformer.class.getResourceAsStream("/" + ASYNC + ".class")) {
            if (in == null)
                return null;
            ClassWriter w = new ClassWriter(0);
            new ClassReader(in.readAllBytes()).accept(new ClassRemapper(w, new SimpleRemapper(ASYNC, ASYNC_AS)), 0);
            return Base64.getEncoder().encodeToString(w.toByteArray());
        } catch (IOException e) {
            return null;
        }
    }

    /** assertMainThread(): "minecraft.isSameThread()" (exactly once) becomes "mcmetal$isSameThread(minecraft)". */
    static void errors(ClassNode c) {
        java.util.List<MethodInsnNode> calls = new java.util.ArrayList<>();
        for (MethodNode m : c.methods)
            if (m.name.equals("assertMainThread") && m.desc.equals("()V") && (m.access & Opcodes.ACC_STATIC) != 0)
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEVIRTUAL && mi.owner.equals(MC)
                            && mi.name.equals("isSameThread") && mi.desc.equals("()Z"))
                        calls.add(mi);
        ClassNode hooks = GpuCullTransformer.readHooks(THREAD_HOOKS);
        if (calls.size() != 1 || hooks == null || hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>"))) {
            MetalBootstrap.log("JEI start: JEI's thread check is not the expected one, left as it is");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        LoadSpeedTransformer.redirect(calls.get(0), c.name, "isSameThread", "(L" + MC + ";)Z");
    }

    @Override
    public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
        return TransformerVoteResult.YES;
    }

    @Override
    public Set<Target<ClassNode>> targets() {
        return Set.of(Target.targetClass(STARTER), Target.targetClass(ERRORS));
    }

    @Override
    public TargetType<ClassNode> getTargetType() {
        return TargetType.CLASS;
    }
}
