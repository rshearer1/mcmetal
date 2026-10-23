package mcmetal.loader;

import java.io.File;
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
 * Then it logs "[mcmetal] control done N". Never starts without the variable.
 *
 * MCMETAL_TEST_SCREEN=inventory (test rig only): once a world is loaded, opens the player's inventory (with JEI's
 * item list beside it when JEI is installed) and opens it again whenever it closes, for menu frame-rate runs.
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
            while (true) {
                Thread.sleep(500);
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
                        else if (!line.startsWith("mark "))
                            MetalBootstrap.log("control: unknown line");
                    } catch (ReflectiveOperationException | RuntimeException e) {
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
        if (player == null || mcc.getField("screen").get(mc) != null)
            return;
        if (!name.equals("inventory")) {
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
                reload.invoke(null);
                MetalBootstrap.log("control: shaders reloaded");
            } catch (ReflectiveOperationException e) {
                MetalBootstrap.log("control: shader reload failed: " + e.getCause());
            }
        };
        mc.getClass().getMethod("execute", Runnable.class).invoke(mc, r);
    }
}
