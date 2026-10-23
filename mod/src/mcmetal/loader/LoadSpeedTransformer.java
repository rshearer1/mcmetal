package mcmetal.loader;

import java.security.MessageDigest;
import java.util.HexFormat;
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
import org.objectweb.asm.tree.IntInsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.TypeInsnNode;
import org.objectweb.asm.tree.VarInsnNode;

/**
 * Loading-time fixes for other mods' slow startup code (on by default, MCMETAL_LOAD_FIXES=0 turns them off), found by
 * profiling Hearth & Hex's full start in the cloud (2026-10-23, 341 mods, 4 slow cores). Each one changes how a result is
 * computed, never the result, and only touches the exact code it was written for; anything else is left alone with a
 * log line. They help with or without Metal, so they don't wait for mcmetal.active. No mod's jar is touched.
 *
 * Hexerei: WoodcutterRecipes.createRecipes() runs at every world start and checked every plank against every recipe
 * (198 s of a 653 s cloud start into an existing world; 9 s with the fix, same 5,829 woodcutter recipes in the same
 * order); see load/WoodcutterHooks.
 * Vegan Delight: VeganLabels.initialize() runs whenever recipes load and asked an ArrayList of up to 57,000 items
 * whether it holds an item, over and over (16-19 s); see load/SeenListHooks.
 * Carry On: ListHandler.initConfigLists() runs whenever tags load and rebuilt every block's name for each of its
 * config's wildcards (5-9 s on the main thread); see load/WildcardNameHooks.
 * KubeJS: a script's replaceInput() walked every item of every recipe ingredient for each item it replaces (8.5 s of
 * Hearth & Hex's recipe load); see load/IngredientMatchHooks.
 */
final class LoadSpeedTransformer implements ITransformer<ClassNode> {
    static final String HEXEREI = "net.joefoxe.hexerei.data.recipes.WoodcutterRecipes";
    static final String VEGAN = "net.player005.vegandelightfabric.labels.VeganLabels";
    static final String WOOD_HOOKS = "mcmetal/loader/load/WoodcutterHooks";
    static final String SEEN_HOOKS = "mcmetal/loader/load/SeenListHooks";
    static final String CARRYON = "tschipp.carryon.common.config.ListHandler";
    static final String NAME_HOOKS = "mcmetal/loader/load/WildcardNameHooks";
    static final String KUBEJS = "dev.latvian.mods.kubejs.recipe.component.IngredientComponent";
    static final String MATCH_HOOKS = "mcmetal/loader/load/IngredientMatchHooks";
    static final String PREFIX = GpuCullTransformer.PREFIX;
    /** createRecipes() of Hexerei 0.5.0.3 (see fingerprint()); any other version keeps its own loop. */
    static final Set<String> KNOWN_CREATE_RECIPES = Set.of("1f31c51f74d9f41b");

    static boolean wanted() {
        return !"0".equals(System.getenv("MCMETAL_LOAD_FIXES"));
    }

    @Override
    public ClassNode transform(ClassNode c, ITransformerVotingContext ctx) {
        if (!wanted())
            return c;
        if (c.name.equals(HEXEREI.replace('.', '/')))
            woodcutter(c);
        else if (c.name.equals(VEGAN.replace('.', '/')))
            veganSeen(c);
        else if (c.name.equals(CARRYON.replace('.', '/')))
            carryOnNames(c);
        else if (c.name.equals(KUBEJS.replace('.', '/')))
            kubeMatches(c);
        return c;
    }

    static void woodcutter(ClassNode c) {
        MethodNode create = null;
        for (MethodNode m : c.methods)
            if (m.name.equals("createRecipes") && m.desc.equals("(Lnet/minecraft/server/MinecraftServer;)V")
                    && (m.access & Opcodes.ACC_STATIC) != 0)
                create = m;
        String print = create == null ? "none" : fingerprint(create);
        // manager.getRecipes() in the plank loop, and the plank: "... next; checkcast Item; astore P; aload 0; getRecipeManager; getRecipes"
        MethodInsnNode call = null;
        int plank = -1;
        if (create != null && KNOWN_CREATE_RECIPES.contains(print))
            for (AbstractInsnNode n : create.instructions.toArray())
                if (n instanceof MethodInsnNode mi && mi.name.equals("getRecipes") && mi.desc.equals("()Ljava/util/Collection;")
                        && mi.owner.equals("net/minecraft/world/item/crafting/RecipeManager")
                        && prev(mi) instanceof MethodInsnNode rm && rm.name.equals("getRecipeManager")
                        && prev(rm) instanceof VarInsnNode server && server.var == 0
                        && prev(server) instanceof VarInsnNode store && store.getOpcode() == Opcodes.ASTORE
                        && prev(store) instanceof TypeInsnNode cast && cast.desc.equals("net/minecraft/world/item/Item")) {
                    call = call == null ? mi : null; // exactly one
                    plank = store.var;
                }
        ClassNode hooks = GpuCullTransformer.readHooks(WOOD_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null; // its static initializer would not be copied
        if (call == null || hooks == null) {
            MetalBootstrap.log("load fixes: Hexerei's woodcutter recipes are not the version this fix was made for ("
                    + print + "), they are built the usual way");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        // createRecipes(server) { mcmetal$begin(server); ...
        InsnList pre = new InsnList();
        pre.add(new VarInsnNode(Opcodes.ALOAD, 0));
        pre.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "begin", "(Lnet/minecraft/server/MinecraftServer;)V", false));
        create.instructions.insert(pre);
        // manager.getRecipes()  ->  mcmetal$recipesFor(manager, plank)
        create.instructions.insertBefore(call, new VarInsnNode(Opcodes.ALOAD, plank));
        call.setOpcode(Opcodes.INVOKESTATIC);
        call.owner = c.name;
        call.name = PREFIX + "recipesFor";
        call.desc = "(Lnet/minecraft/world/item/crafting/RecipeManager;Lnet/minecraft/world/item/Item;)Ljava/util/Collection;";
        call.itf = false;
        create.maxStack += 1;
        MetalBootstrap.log("load fixes: Hexerei's woodcutter recipes are built from an index (MCMETAL_LOAD_FIXES)");
    }

    static void veganSeen(ClassNode c) {
        // initialize(): list.contains, then the end; scanRecipesRecursively(): list.add; recipeNotVegan(): list.contains
        java.util.List<MethodInsnNode> contains = new java.util.ArrayList<>(), adds = new java.util.ArrayList<>();
        java.util.List<AbstractInsnNode> ends = new java.util.ArrayList<>();
        MethodNode init = null;
        for (MethodNode m : c.methods) {
            boolean isInit = m.name.equals("initialize") && m.desc.equals("()V");
            boolean isScan = m.name.equals("scanRecipesRecursively") && m.desc.equals("(Lnet/minecraft/world/item/Item;Ljava/util/List;)V");
            boolean isCheck = m.name.equals("recipeNotVegan") && m.desc.startsWith("(Ljava/util/List;");
            if (isInit)
                init = m;
            for (AbstractInsnNode n : m.instructions.toArray()) {
                if (isInit && n.getOpcode() == Opcodes.RETURN)
                    ends.add(n);
                if (!(n instanceof MethodInsnNode mi))
                    continue;
                if ((isInit && mi.owner.equals("java/util/ArrayList") || isCheck && mi.owner.equals("java/util/List"))
                        && mi.name.equals("contains") && mi.desc.equals("(Ljava/lang/Object;)Z"))
                    contains.add(mi);
                if (isScan && mi.owner.equals("java/util/List") && mi.name.equals("add") && mi.desc.equals("(Ljava/lang/Object;)Z"))
                    adds.add(mi);
            }
        }
        ClassNode hooks = GpuCullTransformer.readHooks(SEEN_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (init == null || contains.size() != 2 || adds.size() != 1 || ends.isEmpty() || hooks == null) {
            MetalBootstrap.log("load fixes: Vegan Delight's labels are not the expected ones, left as they are");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        for (MethodInsnNode mi : contains)
            redirect(mi, c.name, "contains", "(Ljava/util/List;Ljava/lang/Object;)Z");
        redirect(adds.get(0), c.name, "add", "(Ljava/util/List;Ljava/lang/Object;)Z");
        for (AbstractInsnNode n : ends)
            init.instructions.insertBefore(n, new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "done", "()V", false));
        MetalBootstrap.log("load fixes: Vegan Delight's labels keep their seen items in a set (MCMETAL_LOAD_FIXES)");
    }

    static void carryOnNames(ClassNode c) {
        // addWithWildcards(): registry.keySet().toArray(...) once, key.toString() twice in the loop over it;
        // initConfigLists(): the end
        java.util.List<MethodInsnNode> names = new java.util.ArrayList<>(), arrays = new java.util.ArrayList<>();
        java.util.List<AbstractInsnNode> ends = new java.util.ArrayList<>();
        MethodNode init = null;
        for (MethodNode m : c.methods) {
            boolean isAdd = m.name.equals("addWithWildcards") && m.desc.equals(
                    "(Ljava/util/List;Ljava/util/Set;Lnet/minecraft/core/Registry;Ljava/util/Map;Ljava/util/List;)V");
            boolean isInit = m.name.equals("initConfigLists") && m.desc.equals("()V");
            if (isInit)
                init = m;
            for (AbstractInsnNode n : m.instructions.toArray()) {
                if (isInit && n.getOpcode() == Opcodes.RETURN)
                    ends.add(n);
                if (isAdd && n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEVIRTUAL
                        && mi.owner.equals("net/minecraft/resources/ResourceLocation") && mi.name.equals("toString"))
                    names.add(mi);
                if (isAdd && n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEINTERFACE && mi.owner.equals("java/util/Set")
                        && mi.name.equals("toArray") && mi.desc.equals("([Ljava/lang/Object;)[Ljava/lang/Object;")
                        && prev(mi) instanceof TypeInsnNode t && t.getOpcode() == Opcodes.ANEWARRAY
                        && t.desc.equals("net/minecraft/resources/ResourceLocation"))
                    arrays.add(mi);
            }
        }
        ClassNode hooks = GpuCullTransformer.readHooks(NAME_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (init == null || names.size() != 2 || arrays.size() != 1 || ends.isEmpty() || hooks == null) {
            MetalBootstrap.log("load fixes: Carry On's config lists are not the expected ones, left as they are");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        redirect(arrays.get(0), c.name, "keys", "(Ljava/util/Set;[Ljava/lang/Object;)[Ljava/lang/Object;");
        for (MethodInsnNode mi : names)
            redirect(mi, c.name, "name", "(Ljava/lang/Object;)Ljava/lang/String;");
        for (AbstractInsnNode n : ends)
            init.instructions.insertBefore(n, new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "done", "()V", false));
        MetalBootstrap.log("load fixes: Carry On's wildcard lists name each id once (MCMETAL_LOAD_FIXES)");
    }

    static void kubeMatches(ClassNode c) {
        // matches(cx, Ingredient, info): "itemMatch.matches(cx, ingredient, info.exact())", exactly once
        String match = "dev/latvian/mods/kubejs/recipe/match/ItemMatch";
        String cx = "Ldev/latvian/mods/kubejs/recipe/filter/RecipeMatchContext;";
        String ing = "Lnet/minecraft/world/item/crafting/Ingredient;";
        java.util.List<MethodInsnNode> calls = new java.util.ArrayList<>();
        for (MethodNode m : c.methods)
            if (m.name.equals("matches") && m.desc.equals("(" + cx + ing + "Ldev/latvian/mods/kubejs/recipe/match/ReplacementMatchInfo;)Z"))
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEINTERFACE && mi.owner.equals(match)
                            && mi.name.equals("matches") && mi.desc.equals("(" + cx + ing + "Z)Z"))
                        calls.add(mi);
        ClassNode hooks = GpuCullTransformer.readHooks(MATCH_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (calls.size() != 1 || hooks == null) {
            MetalBootstrap.log("load fixes: KubeJS's ingredient matching is not the expected one, left as it is");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        redirect(calls.get(0), c.name, "matches", "(L" + match + ";" + cx + ing + "Z)Z");
        MetalBootstrap.log("load fixes: KubeJS's replaceInput looks items up in each ingredient's set (MCMETAL_LOAD_FIXES)");
    }

    /** A call on the object in front of its arguments becomes a static call of the merged hook with the same order. */
    static void redirect(MethodInsnNode mi, String owner, String hook, String desc) {
        mi.setOpcode(Opcodes.INVOKESTATIC);
        mi.owner = owner;
        mi.name = PREFIX + hook;
        mi.desc = desc;
        mi.itf = false;
    }

    /** The instruction before n, skipping labels and line numbers. */
    static AbstractInsnNode prev(AbstractInsnNode n) {
        do
            n = n.getPrevious();
        while (n != null && n.getOpcode() < 0);
        return n;
    }

    /** A short hash of what a method does (instructions, the members they use, constants), ignoring line numbers. */
    static String fingerprint(MethodNode m) {
        try {
            MessageDigest d = MessageDigest.getInstance("SHA-256");
            StringBuilder s = new StringBuilder();
            for (AbstractInsnNode n : m.instructions.toArray()) {
                if (n.getOpcode() < 0)
                    continue; // labels, line numbers, frames
                s.append(n.getOpcode()).append(' ');
                if (n instanceof MethodInsnNode mi)
                    s.append(mi.owner).append('.').append(mi.name).append(mi.desc);
                else if (n instanceof FieldInsnNode f)
                    s.append(f.owner).append('.').append(f.name).append(f.desc);
                else if (n instanceof TypeInsnNode t)
                    s.append(t.desc);
                else if (n instanceof VarInsnNode v)
                    s.append(v.var);
                else if (n instanceof LdcInsnNode l)
                    s.append(l.cst);
                else if (n instanceof IntInsnNode i)
                    s.append(i.operand);
                s.append('\n');
            }
            return HexFormat.of().formatHex(d.digest(s.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8))).substring(0, 16);
        } catch (java.security.NoSuchAlgorithmException e) {
            return "?";
        }
    }

    @Override
    public TransformerVoteResult castVote(ITransformerVotingContext ctx) {
        return TransformerVoteResult.YES;
    }

    @Override
    public Set<Target<ClassNode>> targets() {
        return Set.of(Target.targetClass(HEXEREI), Target.targetClass(VEGAN), Target.targetClass(CARRYON), Target.targetClass(KUBEJS));
    }

    @Override
    public TargetType<ClassNode> getTargetType() {
        return TargetType.CLASS;
    }
}
