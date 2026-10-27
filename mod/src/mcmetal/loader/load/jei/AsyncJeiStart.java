package mcmetal.loader.load.jei;

import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import com.google.common.collect.ImmutableSetMultimap;
import mezz.jei.api.IModPlugin;
import mezz.jei.api.recipe.transfer.IRecipeTransferManager;
import mezz.jei.api.runtime.IScreenHelper;
import mezz.jei.api.search.ISearchStorageBuilderFactory;
import mezz.jei.common.Internal;
import mezz.jei.common.config.IIngredientFilterConfig;
import mezz.jei.common.platform.Services;
import mezz.jei.common.recipes.VanillaClientRecipeLoader;
import mezz.jei.common.util.LoggedTimer;
import mezz.jei.common.util.RegistryUtil;
import mezz.jei.library.color.ColorHelper;
import mezz.jei.library.config.EditModeConfig;
import mezz.jei.library.focus.FocusFactory;
import mezz.jei.library.helpers.CodecHelper;
import mezz.jei.library.ingredients.IngredientManager;
import mezz.jei.library.ingredients.subtypes.SubtypeManager;
import mezz.jei.library.load.PluginCaller;
import mezz.jei.library.load.PluginLoader;
import mezz.jei.library.load.registration.RuntimeRegistration;
import mezz.jei.library.recipes.RecipeManager;
import mezz.jei.library.runtime.JeiHelpers;
import mezz.jei.library.runtime.JeiRuntime;
import mezz.jei.library.startup.IStopCallback;
import mezz.jei.library.startup.JeiStarter;
import mezz.jei.library.startup.PluginAwareJeiFeatures;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ClientLevel;
import net.minecraft.core.RegistryAccess;
import net.minecraft.world.item.crafting.RecipeHolder;

/**
 * JEI's start after joining a world, with its slow middle on a background thread (opt-in: MCMETAL_ASYNC_JEI=1 in the
 * environment or mcmetal/options.txt; see JeiStartTransformer). Idea from Nitro (MIT, github.com/TinsleyDevers/Nitro,
 * fix 14); this is our own code, following JEI 19.x's JeiStarter.start() step by step.
 *
 * JEI builds its whole runtime on the render thread when a world is joined: the game stalls for that long (about 12 s
 * on the M3 with Hearth & Hex, 2026-10-27). Here the steps that touch the game's own state stay on the render thread
 * (configuring JEI, subtypes, ingredients), recipe registration and JEI's own runtime plugins (the ingredient list and
 * its search index) run on one background thread, and the rest (other mods' runtime plugins, the hand-over) runs back
 * on the render thread. If the world changes meanwhile the half-built runtime is thrown away; if anything throws, it
 * is thrown away and JEI starts the usual way.
 *
 * Not loaded from mcmetal's jar: JeiStartTransformer renames this class into JEI's package
 * (mezz.jei.library.startup.McmetalAsyncJei) and defines it next to JeiStarter, whose fields it reads (the transformer
 * makes them public). The generation counter lives in JeiStarter (mcmetal$generation) so that stop() can bump it.
 */
public final class AsyncJeiStart {
    static final String THREAD = "mcmetal JEI start";
    private static ExecutorService worker;
    private static boolean pending; // a background build is in flight (render thread only)

    private AsyncJeiStart() {
    }

    /** From JeiStarter.start() on the render thread: true when the start was taken over. */
    public static boolean start(JeiStarter starter) {
        Minecraft mc = Minecraft.getInstance();
        if (pending) { // a build is still running: start again once it has finished or been discarded
            int asked = ++JeiStarter.mcmetal$generation;
            worker().execute(() -> mc.execute(() -> {
                if (asked == JeiStarter.mcmetal$generation)
                    starter.start();
            }));
            return true;
        }
        ClientLevel level = mc.level;
        if (starter.running || level == null)
            return false; // JEI's own start logs these
        RegistryAccess access = level.registryAccess();
        RegistryUtil.setRegistryAccess(access);
        if (!Internal.hasClientRecipes()) {
            List<RecipeHolder<?>> vanilla = VanillaClientRecipeLoader.getVanillaRecipes(access);
            if (!vanilla.isEmpty()) {
                Internal.setClientFallbackRecipes(vanilla);
                level.getRecipeManager().replaceRecipes(vanilla);
            }
        }
        int gen = ++JeiStarter.mcmetal$generation;
        List<IModPlugin> plugins = starter.plugins;
        LoggedTimer total = new LoggedTimer();
        total.start("Starting JEI (mcmetal: recipes on a background thread)");
        starter.configManager.onJeiStarted();
        PluginCaller.callOnPlugins("Configuring JEI", plugins,
                p -> p.configureJei(new PluginAwareJeiFeatures(Internal.getJeiFeatures(), p)));
        ColorHelper colors = new ColorHelper(starter.colorNameConfig);
        IIngredientFilterConfig filterConfig = starter.jeiClientConfigs.getIngredientFilterConfig();
        SubtypeManager subtypes = PluginLoader.registerSubtypes(starter.data);
        IngredientManager ingredients = PluginLoader.registerIngredients(starter.data, subtypes, colors, filterConfig);
        List<IStopCallback> stops = new ArrayList<>();
        stops.add(ingredients::onRuntimeStopped);
        List<IModPlugin> jeiPlugins = new ArrayList<>(), modPlugins = new ArrayList<>();
        for (IModPlugin p : plugins)
            ("jei".equals(p.getPluginUid().getNamespace()) ? jeiPlugins : modPlugins).add(p);

        pending = true;
        worker().execute(() -> {
            try {
                if (gen != JeiStarter.mcmetal$generation) {
                    mc.execute(() -> discard(stops, "the world changed"));
                    return;
                }
                FocusFactory focus = new FocusFactory(ingredients);
                CodecHelper codecs = new CodecHelper(ingredients, focus);
                Path configDir = Services.PLATFORM.getConfigHelper().createJeiConfigDir();
                EditModeConfig editMode = new EditModeConfig(
                        new EditModeConfig.FileSerializer(configDir.resolve("blacklist.json"), access, codecs), ingredients);
                ImmutableSetMultimap<String, String> aliases = PluginLoader.registerModAliases(starter.data, filterConfig);
                JeiHelpers helpers = PluginLoader.createJeiHelpers(aliases, starter.modIdFormatConfig, colors, editMode, focus,
                        codecs, ingredients, subtypes);
                stops.add(helpers::onRuntimeStopped);
                ISearchStorageBuilderFactory search = PluginLoader.createSearchStorageFactory(plugins);
                RecipeManager recipes = PluginLoader.createRecipeManager(plugins, starter.vanillaPlugin,
                        starter.recipeCategorySortingConfig, helpers, ingredients);
                if (gen != JeiStarter.mcmetal$generation) {
                    mc.execute(() -> discard(stops, "the world changed"));
                    return;
                }
                IRecipeTransferManager transfers = PluginLoader.createRecipeTransferManager(starter.vanillaPlugin, plugins,
                        helpers, starter.data.serverConnection());
                LoggedTimer timer = new LoggedTimer();
                timer.start("Building runtime");
                IScreenHelper screens = PluginLoader.createGuiScreenHelper(plugins, helpers, ingredients);
                RuntimeRegistration runtime = new RuntimeRegistration(recipes, helpers, editMode, ingredients, transfers,
                        screens, search);
                PluginCaller.callOnPlugins("Registering Runtime (JEI, background)", jeiPlugins, p -> p.registerRuntime(runtime));
                timer.stop();
                mc.execute(() -> finish(starter, gen, plugins, modPlugins, runtime, recipes, ingredients, helpers, screens,
                        transfers, editMode, stops, total));
            } catch (Throwable t) {
                if (t instanceof Error && !(t instanceof LinkageError)) { // out of memory and the like: not ours to hide
                    mc.execute(() -> {
                        discard(stops, "error");
                        throw (Error) t;
                    });
                    return;
                }
                System.out.println("[mcmetal] JEI's background start failed, starting it the usual way: " + t);
                t.printStackTrace();
                mc.execute(() -> fallback(starter, gen, stops));
            }
        });
        return true;
    }

    private static void finish(JeiStarter starter, int gen, List<IModPlugin> plugins, List<IModPlugin> modPlugins,
            RuntimeRegistration runtime, RecipeManager recipes, IngredientManager ingredients, JeiHelpers helpers,
            IScreenHelper screens, IRecipeTransferManager transfers, EditModeConfig editMode, List<IStopCallback> stops,
            LoggedTimer total) {
        if (gen != JeiStarter.mcmetal$generation || starter.running) {
            discard(stops, "the world changed");
            return;
        }
        try {
            PluginCaller.callOnPlugins("Registering Runtime", modPlugins, p -> p.registerRuntime(runtime));
            JeiRuntime jei = new JeiRuntime(recipes, ingredients, Internal.getKeyMappings(), helpers, screens, transfers,
                    editMode, runtime.getIngredientListOverlay(), runtime.getBookmarkOverlay(), runtime.getRecipesGui(),
                    runtime.getIngredientFilter(), starter.configManager);
            PluginCaller.callOnPlugins("Sending Runtime", plugins, p -> p.onRuntimeAvailable(jei));
            starter.stopCallbacks.addAll(stops);
            Internal.setRuntime(jei);
            starter.running = true;
            pending = false;
            total.stop();
            starter.verifyClientRecipes(Minecraft.getInstance());
        } catch (Exception e) {
            System.out.println("[mcmetal] JEI's hand-over failed, starting it the usual way: " + e);
            e.printStackTrace();
            fallback(starter, gen, stops);
        }
    }

    private static void fallback(JeiStarter starter, int gen, List<IStopCallback> stops) {
        discard(stops, "starting JEI the usual way");
        if (gen != JeiStarter.mcmetal$generation || starter.running || Minecraft.getInstance().level == null)
            return;
        JeiStarter.mcmetal$usual = true;
        try {
            starter.start();
        } finally {
            JeiStarter.mcmetal$usual = false;
        }
    }

    /** Render thread: let a half-built runtime go. */
    private static void discard(List<IStopCallback> stops, String why) {
        pending = false;
        System.out.println("[mcmetal] JEI: dropping a half-built runtime (" + why + ")");
        for (IStopCallback s : stops)
            try {
                s.onRuntimeStopped();
            } catch (Throwable t) {
                System.out.println("[mcmetal] JEI: " + t);
            }
        stops.clear();
    }

    private static synchronized ExecutorService worker() {
        if (worker == null)
            worker = Executors.newSingleThreadExecutor(r -> {
                Thread t = new Thread(r, THREAD);
                t.setDaemon(true);
                t.setPriority(Thread.NORM_PRIORITY - 1);
                return t;
            });
        return worker;
    }
}
