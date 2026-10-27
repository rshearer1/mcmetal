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
 * Create: its ItemStack mixin looked every new stack's item up in the item registry to see if it is a clipboard (a
 * quarter of JEI's start after joining a world in the cloud test, 2026-10-25); see load/ClipboardHooks.
 * Block model names: with FerriteCore, BlockModelShaper.statePropertiesToString() built a slow entry set for every block
 * state each time a model loader named it (~40% of the M3's model loading thread before the title screen, 2026-10-25);
 * see load/StateNameHooks.
 * Moonlight: its generated-asset cache fingerprint holds each resource pack's description as text, which for translated
 * descriptions changes once the mods' language files load, so Every Compat rebuilt its assets on the first F3+T or
 * resource pack change of every session (27.8 s of a 77 s cloud F3+T, 2026-10-26); see load/PackTextHooks.
 * Entity Model Features: each custom model file it looks for and doesn't find was searched for in every resource pack
 * (~4 s of the render thread per F3+T in the cloud, 2026-10-26); see load/ModelFileHooks.
 * Farmer's Delight: each "any knife"-style ingredient made and asked a stack of every registered item, once per recipe
 * (and JEI and KubeJS ask every recipe); see load/AbilityItemsHooks.
 * ModernFix with Puffish Attributes: ModernFix's attribute template set could never find Puffish's NaN-based templates
 * and walked past all earlier ones for each (quadratic over mob types at startup); see load/AttributeTemplateHooks.
 * These last two follow fixes 16 and 13 of Nitro (MIT, github.com/TinsleyDevers/Nitro), written again here.
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
    static final String CREATE_STACK = "com.simibubi.create.foundation.mixin.ItemStackMixin";
    static final String CLIP_HOOKS = "mcmetal/loader/load/ClipboardHooks";
    static final String SHAPER = "net.minecraft.client.renderer.block.BlockModelShaper";
    static final String STATE_HOOKS = "mcmetal/loader/load/StateNameHooks";
    static final String MOONLIGHT_CACHE = "net.mehvahdjukaar.moonlight.api.resources.pack.GlobalCachedStrategy";
    static final String PACK_HOOKS = "mcmetal/loader/load/PackTextHooks";
    static final String EMF_CACHE = "traben.entity_model_features.utils.EMFResourceCaching";
    static final String MODEL_FILE_HOOKS = "mcmetal/loader/load/ModelFileHooks";
    static final String FD_ABILITY = "vectorwing.farmersdelight.common.crafting.ingredient.ItemAbilityIngredient";
    static final String ABILITY_HOOKS = "mcmetal/loader/load/AbilityItemsHooks";
    static final String MF_TEMPLATES = "org.embeddedt.modernfix.entity.AttributeInstanceTemplates";
    static final String TEMPLATE_HOOKS = "mcmetal/loader/load/AttributeTemplateHooks";
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
        else if (c.name.equals(CREATE_STACK.replace('.', '/')))
            createClipboard(c);
        else if (c.name.equals(SHAPER.replace('.', '/')))
            stateNames(c);
        else if (c.name.equals(MOONLIGHT_CACHE.replace('.', '/')))
            packFingerprint(c);
        else if (c.name.equals(EMF_CACHE.replace('.', '/')))
            emfFiles(c);
        else if (c.name.equals(FD_ABILITY.replace('.', '/')))
            abilityItems(c);
        else if (c.name.equals(MF_TEMPLATES.replace('.', '/')))
            attributeTemplates(c);
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

    /**
     * Create's ItemStackMixin (Create 6.0.x) runs create$migrateOldClipboardComponents() in every ItemStack constructor;
     * its first line "if (!BuiltInRegistries.ITEM.getKey(item.asItem()).equals(CLIPBOARD_ID)) return;" becomes
     * "if (!mcmetal$isClipboard(item, CLIPBOARD_ID)) return;", see load/ClipboardHooks. This class is the mixin itself:
     * Mixin reads it through the transformers before copying its methods into ItemStack.
     */
    static void createClipboard(ClassNode c) {
        String itemLike = "net/minecraft/world/level/ItemLike", loc = "net/minecraft/resources/ResourceLocation";
        String desc = "(L" + itemLike + ";ILnet/minecraft/core/component/PatchedDataComponentMap;"
                + "Lorg/spongepowered/asm/mixin/injection/callback/CallbackInfo;)V";
        MethodNode migrate = null;
        MethodInsnNode equals = null;
        AbstractInsnNode[] gone = null; // ITEM, asItem(), getKey()
        int found = 0;
        for (MethodNode m : c.methods)
            if (m.name.equals("create$migrateOldClipboardComponents") && m.desc.equals(desc))
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode eq && eq.getOpcode() == Opcodes.INVOKEVIRTUAL && eq.owner.equals(loc)
                            && eq.name.equals("equals") && eq.desc.equals("(Ljava/lang/Object;)Z")
                            && prev(eq) instanceof FieldInsnNode id && id.getOpcode() == Opcodes.GETSTATIC && id.owner.equals(c.name)
                            && id.desc.equals("L" + loc + ";")
                            && prev(id) instanceof MethodInsnNode key && key.name.equals("getKey")
                            && key.owner.equals("net/minecraft/core/DefaultedRegistry")
                            && prev(key) instanceof MethodInsnNode as && as.name.equals("asItem") && as.owner.equals(itemLike)
                            && prev(as) instanceof VarInsnNode v && v.getOpcode() == Opcodes.ALOAD && v.var == 1
                            && prev(v) instanceof FieldInsnNode reg && reg.getOpcode() == Opcodes.GETSTATIC
                            && reg.owner.equals("net/minecraft/core/registries/BuiltInRegistries") && reg.name.equals("ITEM")) {
                        migrate = m;
                        equals = eq;
                        gone = new AbstractInsnNode[] {reg, as, key};
                        found++;
                    }
        ClassNode hooks = GpuCullTransformer.readHooks(CLIP_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (found != 1 || hooks == null) {
            MetalBootstrap.log("load fixes: Create's clipboard check is not the expected one, left as it is");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        // ITEM, item, asItem(), getKey(), CLIPBOARD_ID, equals()  ->  item, CLIPBOARD_ID, mcmetal$isClipboard()
        for (AbstractInsnNode n : gone)
            migrate.instructions.remove(n);
        redirect(equals, c.name, "isClipboard", "(L" + itemLike + ";L" + loc + ";)Z");
        MetalBootstrap.log("load fixes: Create's clipboard check compares items (MCMETAL_LOAD_FIXES)");
    }

    /**
     * statePropertiesToString(map) becomes "return mcmetal$propertiesString(map);", see load/StateNameHooks. Only when its
     * body is vanilla's (one map.entrySet() walk, nothing else calling out but StringBuilder, Property and its own getValue).
     */
    static void stateNames(ClassNode c) {
        MethodNode target = null;
        int entrySets = 0, others = 0;
        for (MethodNode m : c.methods)
            if (m.name.equals("statePropertiesToString") && m.desc.equals("(Ljava/util/Map;)Ljava/lang/String;")
                    && (m.access & Opcodes.ACC_STATIC) != 0) {
                target = m;
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi) {
                        if (mi.owner.equals("java/util/Map") && mi.name.equals("entrySet"))
                            entrySets++;
                        else if (!(mi.owner.equals("java/lang/StringBuilder") || mi.owner.equals("java/util/Set")
                                || mi.owner.equals("java/util/Iterator") || mi.owner.equals("java/util/Map$Entry")
                                || mi.owner.equals("net/minecraft/world/level/block/state/properties/Property")
                                || mi.owner.equals(c.name) && mi.name.equals("getValue")))
                            others++;
                    }
            }
        ClassNode hooks = GpuCullTransformer.readHooks(STATE_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (target == null || entrySets != 1 || others != 0 || hooks == null) {
            MetalBootstrap.log("load fixes: block model names are not built the expected way, left as they are");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        InsnList body = new InsnList();
        body.add(new VarInsnNode(Opcodes.ALOAD, 0));
        body.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "propertiesString", "(Ljava/util/Map;)Ljava/lang/String;", false));
        body.add(new org.objectweb.asm.tree.InsnNode(Opcodes.ARETURN));
        target.instructions = body;
        target.tryCatchBlocks.clear();
        target.localVariables = null;
        target.maxLocals = 1;
        target.maxStack = 1;
        MetalBootstrap.log("load fixes: block model names are built straight from the state's properties (MCMETAL_LOAD_FIXES)");
    }

    /**
     * computeTokens(packs): "description.getString()" (exactly once) becomes "mcmetal$packText(description)", see
     * load/PackTextHooks.
     */
    static void packFingerprint(ClassNode c) {
        String component = "net/minecraft/network/chat/Component";
        java.util.List<MethodInsnNode> calls = new java.util.ArrayList<>();
        for (MethodNode m : c.methods)
            if (m.name.equals("computeTokens") && m.desc.equals("(Ljava/util/Collection;)Ljava/util/List;")
                    && (m.access & Opcodes.ACC_STATIC) != 0)
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEINTERFACE && mi.owner.equals(component)
                            && mi.name.equals("getString") && mi.desc.equals("()Ljava/lang/String;"))
                        calls.add(mi);
        ClassNode hooks = GpuCullTransformer.readHooks(PACK_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (calls.size() != 1 || hooks == null) {
            MetalBootstrap.log("load fixes: Moonlight's asset cache check is not the expected one, left as it is");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        redirect(calls.get(0), c.name, "packText", "(L" + component + ";)Ljava/lang/String;");
        MetalBootstrap.log("load fixes: Moonlight's asset cache check reads pack descriptions the same in every language (MCMETAL_LOAD_FIXES)");
    }

    /**
     * resourceExists(manager, location): "manager.getResource(location)" (exactly once) becomes
     * "mcmetal$getResource(manager, location)", and clearCache() starts with "mcmetal$reset()"; see load/ModelFileHooks.
     */
    static void emfFiles(ClassNode c) {
        String rm = "net/minecraft/server/packs/resources/ResourceManager", loc = "net/minecraft/resources/ResourceLocation";
        java.util.List<MethodInsnNode> calls = new java.util.ArrayList<>();
        MethodNode clear = null;
        for (MethodNode m : c.methods) {
            if (m.name.equals("clearCache") && m.desc.equals("()V") && (m.access & Opcodes.ACC_STATIC) != 0)
                clear = m;
            if (m.name.equals("resourceExists") && m.desc.equals("(L" + rm + ";L" + loc + ";)Z") && (m.access & Opcodes.ACC_STATIC) != 0)
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEINTERFACE && mi.owner.equals(rm)
                            && mi.name.equals("getResource") && mi.desc.equals("(L" + loc + ";)Ljava/util/Optional;"))
                        calls.add(mi);
        }
        ClassNode hooks = GpuCullTransformer.readHooks(MODEL_FILE_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (calls.size() != 1 || clear == null || hooks == null) {
            MetalBootstrap.log("load fixes: Entity Model Features' model file check is not the expected one, left as it is");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        redirect(calls.get(0), c.name, "getResource", "(L" + rm + ";L" + loc + ";)Ljava/util/Optional;");
        clear.instructions.insert(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "reset", "()V", false));
        MetalBootstrap.log("load fixes: Entity Model Features looks for model files in one listing of its folders (MCMETAL_LOAD_FIXES)");
    }

    /**
     * dissolve(): "if (itemStacks == null) itemStacks = BuiltInRegistries.ITEM.stream().map(ItemStack::new)
     * .filter(s -> s.canPerformAction(itemAbility));" (Farmer's Delight 1.3.x) keeps its null check and store, and the
     * stream between them becomes "mcmetal$stacks(itemAbility)", see load/AbilityItemsHooks. Only when the method is
     * exactly that and its filter only asks canPerformAction(itemAbility).
     */
    static void abilityItems(ClassNode c) {
        String ability = "Lnet/neoforged/neoforge/common/ItemAbility;", stream = "Ljava/util/stream/Stream;";
        MethodNode dissolve = null;
        boolean filterOk = false;
        for (MethodNode m : c.methods) {
            if (m.name.equals("dissolve") && m.desc.equals("()V"))
                dissolve = m;
            if (m.name.startsWith("lambda$dissolve$") && m.desc.equals("(Lnet/minecraft/world/item/ItemStack;)Z")) {
                java.util.List<AbstractInsnNode> code = new java.util.ArrayList<>();
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n.getOpcode() >= 0)
                        code.add(n);
                filterOk = code.size() == 5 && code.get(2) instanceof FieldInsnNode f && f.name.equals("itemAbility")
                        && code.get(3) instanceof MethodInsnNode can && can.name.equals("canPerformAction")
                        && can.desc.equals("(" + ability + ")Z") && code.get(4).getOpcode() == Opcodes.IRETURN;
            }
        }
        // getfield itemStacks, ifnonnull, aload 0, getstatic ITEM, stream, indy, map, aload 0, indy, filter, putfield itemStacks, return
        java.util.List<AbstractInsnNode> code = new java.util.ArrayList<>();
        if (dissolve != null)
            for (AbstractInsnNode n : dissolve.instructions.toArray())
                if (n.getOpcode() >= 0)
                    code.add(n);
        boolean shape = code.size() == 13 && code.get(0) instanceof VarInsnNode
                && code.get(1) instanceof FieldInsnNode get && get.name.equals("itemStacks") && get.desc.equals(stream)
                && code.get(2).getOpcode() == Opcodes.IFNONNULL && code.get(3) instanceof VarInsnNode
                && code.get(4) instanceof FieldInsnNode reg && reg.name.equals("ITEM")
                && reg.owner.equals("net/minecraft/core/registries/BuiltInRegistries")
                && code.get(5) instanceof MethodInsnNode s1 && s1.name.equals("stream")
                && code.get(7) instanceof MethodInsnNode s2 && s2.name.equals("map")
                && code.get(10) instanceof MethodInsnNode s3 && s3.name.equals("filter")
                && code.get(11) instanceof FieldInsnNode put && put.getOpcode() == Opcodes.PUTFIELD && put.name.equals("itemStacks")
                && code.get(12).getOpcode() == Opcodes.RETURN;
        ClassNode hooks = GpuCullTransformer.readHooks(ABILITY_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (!shape || !filterOk || hooks == null) {
            MetalBootstrap.log("load fixes: Farmer's Delight's tool ingredients are not the expected ones, left as they are");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        for (int i = 4; i <= 10; i++) // ITEM ... filter(); the "this" for the store stays
            dissolve.instructions.remove(code.get(i));
        InsnList call = new InsnList();
        call.add(new VarInsnNode(Opcodes.ALOAD, 0));
        call.add(new FieldInsnNode(Opcodes.GETFIELD, c.name, "itemAbility", ability));
        call.add(new MethodInsnNode(Opcodes.INVOKESTATIC, c.name, PREFIX + "stacks", "(" + ability + ")" + stream, false));
        dissolve.instructions.insertBefore(code.get(11), call);
        MetalBootstrap.log("load fixes: Farmer's Delight finds each tool ingredient's items once (MCMETAL_LOAD_FIXES)");
    }

    /** intern(template): "INTERNER.addOrGet(template)" (exactly once) becomes "mcmetal$addOrGet(INTERNER, template)". */
    static void attributeTemplates(ClassNode c) {
        String set = "it/unimi/dsi/fastutil/objects/ObjectOpenCustomHashSet";
        java.util.List<MethodInsnNode> calls = new java.util.ArrayList<>();
        for (MethodNode m : c.methods)
            if (m.name.equals("intern") && (m.access & Opcodes.ACC_STATIC) != 0)
                for (AbstractInsnNode n : m.instructions.toArray())
                    if (n instanceof MethodInsnNode mi && mi.getOpcode() == Opcodes.INVOKEVIRTUAL && mi.owner.equals(set)
                            && mi.name.equals("addOrGet") && mi.desc.equals("(Ljava/lang/Object;)Ljava/lang/Object;"))
                        calls.add(mi);
        ClassNode hooks = GpuCullTransformer.readHooks(TEMPLATE_HOOKS);
        if (hooks != null && hooks.methods.stream().anyMatch(m -> m.name.equals("<clinit>")))
            hooks = null;
        if (calls.size() != 1 || hooks == null) {
            MetalBootstrap.log("load fixes: ModernFix's attribute templates are not the expected ones, left as they are");
            return;
        }
        GpuCullTransformer.merge(hooks, c);
        redirect(calls.get(0), c.name, "addOrGet", "(L" + set + ";Ljava/lang/Object;)Ljava/lang/Object;");
        MetalBootstrap.log("load fixes: ModernFix leaves NaN attribute templates unshared without searching (MCMETAL_LOAD_FIXES)");
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
        return Set.of(Target.targetClass(HEXEREI), Target.targetClass(VEGAN), Target.targetClass(CARRYON), Target.targetClass(KUBEJS),
                Target.targetClass(CREATE_STACK), Target.targetClass(SHAPER), Target.targetClass(MOONLIGHT_CACHE),
                Target.targetClass(EMF_CACHE), Target.targetClass(FD_ABILITY), Target.targetClass(MF_TEMPLATES));
    }

    @Override
    public TargetType<ClassNode> getTargetType() {
        return TargetType.CLASS;
    }
}
