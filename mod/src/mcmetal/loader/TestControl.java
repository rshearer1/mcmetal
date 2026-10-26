package mcmetal.loader;

import java.io.File;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.util.List;

/**
 * MCMETAL_CONTROL=FILE (test rig only): lets the rig change the scene without relaunching the game, so one launch can
 * measure several times of day, camera angles or shader pack options. Twice a second, if FILE exists it is read and
 * deleted, and each line runs in order:
 *   cmd COMMAND      a server command in the singleplayer world (full permissions, no cheats needed), e.g.
 *                    "cmd time set 12300" or "cmd reload" (reloads the world's datapacks, e.g. a rewritten look)
 *   shaders          reloads the shader pack (Iris re-reads iris.properties and the pack's options file)
 *   mark TEXT        just logs "[mcmetal] mark TEXT", for the rig to find its place in the log
 *   resources        reloads the resource packs as F3+T does, then logs "[mcmetal] control: resources reloaded in N ms"
 *   dimension DIM    sends the player to dimension DIM (e.g. minecraft:the_nether, at 0 120 0), then logs
 *                    "[mcmetal] control: dimension DIM ready in N ms" once the player is there with no loading screen
 *   leave            leaves the world as the pause menu's button does, then logs "[mcmetal] control: left the world in
 *                    N ms" once the title screen is back (the "Saving world" wait)
 * The timed lines wait (up to 3 minutes) before the next line runs, so a file can time several in a row.
 * Then it logs "[mcmetal] control done N". Never starts without the variable.
 *
 * MCMETAL_TEST_SCREEN=inventory (test rig only): once a world is loaded, opens the player's inventory (with JEI's
 * item list beside it when JEI is installed) and opens it again whenever it closes, for menu frame-rate runs.
 * MCMETAL_TEST_SCREEN=creative does the same in creative mode (the inventory becomes the creative menu) and picks the
 * search tab, which lists every item; creative-scroll also scrolls that list down a little every 100 ms (wrapping at
 * the end), as someone browsing it does.
 */
final class TestControl {
    private TestControl() {
    }

    static void start(String path) {
        Thread t = new Thread(() -> run(path == null || path.isEmpty() ? null : new File(path)), "mcmetal test control");
        t.setDaemon(true);
        t.start();
    }

    private static void run(File file) {
        try {
            Method getInstance = null;
            ClassLoader cl = null;
            while (getInstance == null) {
                Thread.sleep(2000);
                for (Thread th : Thread.getAllStackTraces().keySet()) {
                    if (!th.getName().equals("Render thread") || th.getContextClassLoader() == null)
                        continue;
                    try {
                        cl = th.getContextClassLoader();
                        getInstance = Class.forName("net.minecraft.client.Minecraft", false, cl).getMethod("getInstance");
                    } catch (ReflectiveOperationException | LinkageError e) {
                        // game classes not loaded yet
                    }
                }
            }
            int done = 0;
            String screen = System.getenv("MCMETAL_TEST_SCREEN");
            boolean scroll = "creative-scroll".equals(screen);
            int ticks = 0;
            while (true) {
                Thread.sleep(scroll ? 100 : 500);
                if (scroll)
                    scrollCreative(getInstance.invoke(null), cl);
                if (scroll && ++ticks % 5 != 0)
                    continue;
                if (screen != null && !screen.isEmpty())
                    holdScreen(getInstance.invoke(null), cl, screen);
                if (file == null || !file.exists())
                    continue;
                List<String> lines = Files.readAllLines(file.toPath());
                if (!file.delete())
                    continue;
                Object mc = getInstance.invoke(null);
                for (String line : lines) {
                    line = line.strip();
                    if (line.isEmpty())
                        continue;
                    MetalBootstrap.log("control: " + line);
                    try {
                        if (line.startsWith("cmd "))
                            command(mc, line.substring(4));
                        else if (line.equals("shaders"))
                            reloadShaders(mc, cl);
                        else if (line.equals("resources"))
                            reloadResources(mc);
                        else if (line.startsWith("dimension "))
                            dimension(mc, line.substring(10).strip());
                        else if (line.equals("leave"))
                            leave(mc, cl);
                        else if (!line.startsWith("mark "))
                            MetalBootstrap.log("control: unknown line");
                    } catch (Exception e) {
                        MetalBootstrap.log("control failed: " + e);
                    }
                }
                MetalBootstrap.log("control done " + (++done));
            }
        } catch (Throwable t) {
            MetalBootstrap.log("test control stopped: " + t);
        }
    }

    private static int screenOpens;

    /** Opens the named screen on the render thread when the world is loaded and no screen is open. */
    private static void holdScreen(Object mc, ClassLoader cl, String name) throws ReflectiveOperationException {
        Class<?> mcc = mc.getClass();
        Object player = mcc.getField("player").get(mc);
        Object open = mcc.getField("screen").get(mc);
        if (player != null && open != null && name.startsWith("creative"))
            pickSearchTab(mc, cl, open);
        if (player == null || open != null)
            return;
        if (!name.equals("inventory") && !name.equals("creative") && !name.equals("creative-scroll")) {
            MetalBootstrap.log("control: unknown MCMETAL_TEST_SCREEN " + name);
            System.exit(1); // a typo must not measure the world instead of a menu
        }
        Class<?> playerClass = Class.forName("net.minecraft.world.entity.player.Player", false, cl);
        Class<?> screenClass = Class.forName("net.minecraft.client.gui.screens.Screen", false, cl);
        var make = Class.forName("net.minecraft.client.gui.screens.inventory.InventoryScreen", true, cl)
                .getConstructor(playerClass);
        Method set = mcc.getMethod("setScreen", screenClass);
        Runnable r = () -> { // screens are made and shown on the render thread
            try {
                if (mcc.getField("screen").get(mc) == null)
                    set.invoke(mc, make.newInstance(player));
            } catch (ReflectiveOperationException e) {
                MetalBootstrap.log("control: opening " + name + " failed: " + e.getCause());
            }
        };
        mcc.getMethod("execute", Runnable.class).invoke(mc, r);
        if (screenOpens++ < 5)
            MetalBootstrap.log("control: screen " + name + " opened");
    }

    private static boolean searchPicked;
    private static final String CREATIVE = "net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen";

    private static boolean isCreative(Object screen) {
        for (Class<?> c = screen == null ? null : screen.getClass(); c != null; c = c.getSuperclass())
            if (c.getName().equals(CREATIVE))
                return true;
        return false;
    }

    /** Switches an open creative menu to its search tab (all items), once, on the render thread. */
    private static void pickSearchTab(Object mc, ClassLoader cl, Object open) throws ReflectiveOperationException {
        // by name: loading game classes on this thread (at the title screen, say) races the game's own loading
        if (searchPicked || !isCreative(open))
            return;
        searchPicked = true;
        Class<?> creative = open.getClass();
        while (!creative.getName().equals(CREATIVE))
            creative = creative.getSuperclass();
        Class<?> tabClass = Class.forName("net.minecraft.world.item.CreativeModeTab", false, cl);
        Object search = Class.forName("net.minecraft.world.item.CreativeModeTabs", true, cl).getMethod("searchTab").invoke(null);
        Method select = creative.getDeclaredMethod("selectTab", tabClass);
        select.setAccessible(true);
        Runnable r = () -> {
            try {
                select.invoke(open, search);
                MetalBootstrap.log("control: creative search tab");
            } catch (ReflectiveOperationException e) {
                MetalBootstrap.log("control: picking the search tab failed: " + e.getCause());
            }
        };
        mc.getClass().getMethod("execute", Runnable.class).invoke(mc, r);
    }

    private static float scrollPos;

    /** Moves an open creative menu's item list down a little (as the mouse wheel does), wrapping at the end. */
    private static void scrollCreative(Object mc, ClassLoader cl) throws ReflectiveOperationException {
        if (!searchPicked)
            return;
        Object open = mc.getClass().getField("screen").get(mc);
        if (!isCreative(open))
            return;
        Class<?> creative = open.getClass();
        while (!creative.getName().equals(CREATIVE))
            creative = creative.getSuperclass();
        Object menu = creative.getMethod("getMenu").invoke(open);
        Field offs = creative.getDeclaredField("scrollOffs");
        offs.setAccessible(true);
        Method scrollTo = menu.getClass().getMethod("scrollTo", float.class);
        scrollPos = scrollPos >= 1f ? 0f : Math.min(1f, scrollPos + 0.01f);
        float to = scrollPos;
        Runnable r = () -> {
            try {
                offs.setFloat(open, to);
                scrollTo.invoke(menu, to);
            } catch (ReflectiveOperationException e) {
                MetalBootstrap.log("control: scrolling failed: " + e.getCause());
            }
        };
        mc.getClass().getMethod("execute", Runnable.class).invoke(mc, r);
    }

    /** A command as the integrated server itself, on the server thread. */
    private static void command(Object mc, String cmd) throws ReflectiveOperationException {
        Object server = mc.getClass().getMethod("getSingleplayerServer").invoke(mc);
        if (server == null) {
            MetalBootstrap.log("control: no world loaded");
            return;
        }
        Object commands = server.getClass().getMethod("getCommands").invoke(server);
        Object source = server.getClass().getMethod("createCommandSourceStack").invoke(server);
        Method perform = null;
        for (Method m : commands.getClass().getMethods())
            if (m.getName().equals("performPrefixedCommand") && m.getParameterCount() == 2)
                perform = m;
        if (perform == null)
            throw new NoSuchMethodException("Commands.performPrefixedCommand");
        Method run = perform;
        Runnable r = () -> {
            try {
                run.invoke(commands, source, cmd);
            } catch (ReflectiveOperationException e) {
                MetalBootstrap.log("control: command failed: " + e);
            }
        };
        server.getClass().getMethod("execute", Runnable.class).invoke(server, r);
    }

    /** Iris.reload() on the render thread, as its own "reload shaders" key does. */
    private static void reloadShaders(Object mc, ClassLoader cl) throws ReflectiveOperationException {
        Method reload = Class.forName("net.irisshaders.iris.Iris", true, cl).getMethod("reload");
        Runnable r = () -> {
            try {
                long t0 = System.nanoTime();
                reload.invoke(null);
                MetalBootstrap.log("control: shaders reloaded in " + (System.nanoTime() - t0) / 1_000_000 + " ms");
            } catch (ReflectiveOperationException e) {
                MetalBootstrap.log("control: shader reload failed: " + e.getCause());
            }
        };
        mc.getClass().getMethod("execute", Runnable.class).invoke(mc, r);
    }

    /** Minecraft.reloadResourcePacks() on the render thread (F3+T); waits for it and logs how long it took. */
    private static void reloadResources(Object mc) throws Exception {
        long t0 = System.nanoTime();
        java.util.concurrent.CompletableFuture<Object> started = new java.util.concurrent.CompletableFuture<>();
        Method reload = mc.getClass().getMethod("reloadResourcePacks");
        Runnable r = () -> {
            try {
                started.complete(reload.invoke(mc));
            } catch (ReflectiveOperationException e) {
                started.completeExceptionally(e);
            }
        };
        mc.getClass().getMethod("execute", Runnable.class).invoke(mc, r);
        Object done = started.get(30, java.util.concurrent.TimeUnit.SECONDS);
        ((java.util.concurrent.CompletableFuture<?>) done).get(3, java.util.concurrent.TimeUnit.MINUTES);
        waitFor(() -> mc.getClass().getMethod("getOverlay").invoke(mc) == null); // the loading overlay fades out after
        MetalBootstrap.log("control: resources reloaded in " + (System.nanoTime() - t0) / 1_000_000 + " ms");
    }

    /** Teleports the player to another dimension and waits until it is there with no screen open. */
    private static void dimension(Object mc, String dim) throws Exception {
        long t0 = System.nanoTime();
        command(mc, "execute in " + dim + " run tp @a 0 120 0");
        waitFor(() -> {
            Object level = mc.getClass().getField("level").get(mc);
            if (level == null || mc.getClass().getField("screen").get(mc) != null)
                return false;
            Object key = level.getClass().getMethod("dimension").invoke(level);
            return String.valueOf(key.getClass().getMethod("location").invoke(key)).equals(dim);
        });
        MetalBootstrap.log("control: dimension " + dim + " ready in " + (System.nanoTime() - t0) / 1_000_000 + " ms");
    }

    /** Leaves the world as the pause menu does (disconnect, then the title screen) and times the save. */
    private static void leave(Object mc, ClassLoader cl) throws Exception {
        long t0 = System.nanoTime();
        Class<?> screenClass = Class.forName("net.minecraft.client.gui.screens.Screen", false, cl);
        Class<?> title = Class.forName("net.minecraft.client.gui.screens.TitleScreen", true, cl);
        Runnable r = () -> {
            try {
                Object level = mc.getClass().getField("level").get(mc);
                if (level != null)
                    level.getClass().getMethod("disconnect").invoke(level);
                mc.getClass().getMethod("disconnect").invoke(mc);
                mc.getClass().getMethod("setScreen", screenClass).invoke(mc, title.getConstructor().newInstance());
            } catch (ReflectiveOperationException e) {
                MetalBootstrap.log("control: leaving failed: " + e.getCause());
            }
        };
        mc.getClass().getMethod("execute", Runnable.class).invoke(mc, r);
        waitFor(() -> mc.getClass().getField("level").get(mc) == null && title.isInstance(mc.getClass().getField("screen").get(mc)));
        MetalBootstrap.log("control: left the world in " + (System.nanoTime() - t0) / 1_000_000 + " ms");
    }

    private interface Check {
        boolean done() throws Exception;
    }

    /** Polls every 20 ms, for at most 3 minutes. */
    private static void waitFor(Check c) throws Exception {
        long end = System.nanoTime() + 180_000_000_000L;
        while (!c.done()) {
            if (System.nanoTime() > end)
                throw new java.util.concurrent.TimeoutException("waited 3 minutes");
            Thread.sleep(20);
        }
    }
}
