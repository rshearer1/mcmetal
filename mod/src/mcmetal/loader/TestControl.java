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
 */
final class TestControl {
    private TestControl() {
    }

    static void start(String path) {
        Thread t = new Thread(() -> run(new File(path)), "mcmetal test control");
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
            while (true) {
                Thread.sleep(500);
                if (!file.exists())
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
