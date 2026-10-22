package mcmetal.loader;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;

import net.neoforged.neoforgespi.earlywindow.GraphicsBootstrapper;

/**
 * Switches Minecraft's OpenGL over to mcmetal before anything opens a window.
 *
 * NeoForge runs every GraphicsBootstrapper found in the mods folder before its early loading screen creates the
 * first GLFW window, so this is the last moment LWJGL can still be pointed at other libraries. We unpack the two
 * dylibs carried in this jar (Java-written files get no quarantine flag, and Apple Silicon only needs the ad-hoc
 * signature the linker already added, so no notarisation is involved) and set LWJGL's libname properties.
 * Anything unexpected leaves the game on Apple's OpenGL.
 */
public final class MetalBootstrap implements GraphicsBootstrapper {
    static final String ACTIVE = "mcmetal.active"; // read by IrisMacroTransformer

    @Override
    public String name() {
        return "mcmetal";
    }

    @Override
    public void bootstrap(String[] args) {
        if (System.getenv("MCMETAL_FPS_LOG") != null || Boolean.getBoolean("mcmetal.fpsLog"))
            FpsLog.start(); // also with Apple's OpenGL, for comparisons
        if (System.getenv("MCMETAL_CONTROL") != null && !System.getenv("MCMETAL_CONTROL").isEmpty())
            TestControl.start(System.getenv("MCMETAL_CONTROL")); // test rig: several scenes in one launch
        try {
            enable(args);
        } catch (Throwable t) {
            log("could not start, keeping Apple's OpenGL: " + t);
        }
    }

    private static void enable(String[] args) throws Exception {
        String os = System.getProperty("os.name", "").toLowerCase();
        if (!os.contains("mac") || !"aarch64".equals(System.getProperty("os.arch"))) {
            log("not an Apple Silicon Mac, nothing to do");
            return;
        }
        if (Boolean.getBoolean("mcmetal.disable") || System.getenv("MCMETAL_DISABLE") != null) {
            log("turned off (mcmetal.disable / MCMETAL_DISABLE)");
            return;
        }
        String preset = System.getProperty("org.lwjgl.opengl.libname");
        if (preset != null) { // JVM arguments win, e.g. a locally built mcmetal
            if (preset.contains("mcmetal"))
                System.setProperty(ACTIVE, "true");
            log("org.lwjgl.opengl.libname is already set to " + preset + ", leaving it");
            return;
        }
        Path home = gameDir(args).resolve("mcmetal");
        Path dir = home.resolve("natives");
        Files.createDirectories(dir);
        // libmcmetal deletes this marker once the game has drawn real screens. If it's still here, the last
        // launch died on the way: use Apple's OpenGL this once, and try Metal again on the launch after.
        Path marker = home.resolve("starting");
        if (Files.exists(marker)) {
            Files.move(marker, home.resolve("last-start-failed"), java.nio.file.StandardCopyOption.REPLACE_EXISTING);
            log("the last launch on Metal did not get to the menu, so this one uses Apple's OpenGL;"
                    + " Metal will be tried again next launch (see mcmetal/last-start-failed)");
            return;
        }
        Path options = home.resolve("options.txt");
        if (!Files.exists(options))
            Files.writeString(options, """
                    # mcmetal options, read when the game starts. Remove the # in front of a line to turn it on.
                    #
                    # Heavy shader packs (SEUS PTGI, path tracing) on a Retina screen: draw at half the resolution
                    # each way and sharpen to full size with Apple's MetalFX upscaler. About 2.5x faster, a little
                    # softer than native.
                    #MCMETAL_UPSCALE=1
                    #
                    # Experimental: MetalFX's temporal upscaler instead (with a shader pack; rebuilds detail from
                    # several frames). Works best with the shader pack's own TAA turned off.
                    #MCMETAL_UPSCALE=2
                    # How big the game renders before upscaling, in % of the Retina size each way (34-100).
                    #MCMETAL_UPSCALE_SCALE=50
                    #
                    # Draw at half resolution on a Retina screen without the upscaler (fastest, softest).
                    #MCMETAL_RETINA=0
                    #
                    # Terrain chunks out of view are skipped on the GPU. Turn it off if terrain ever goes missing.
                    #MCMETAL_GPU_CULL=0
                    """);
        Path gl = unpack("libmcmetal.dylib", dir);
        Path glfw = unpack("libglfw.dylib", dir); // finds libmcmetal.dylib next to itself
        Files.writeString(marker, "mcmetal was starting at " + java.time.Instant.now() + "\n");
        System.setProperty("org.lwjgl.opengl.libname", gl.toString());
        System.setProperty("org.lwjgl.glfw.libname", glfw.toString());
        System.setProperty(ACTIVE, "true");
        log("OpenGL now runs on Metal through " + gl);
    }

    private static Path gameDir(String[] args) {
        for (int i = 0; i + 1 < args.length; i++)
            if (args[i].equals("--gameDir"))
                return Path.of(args[i + 1]).toAbsolutePath();
        return Path.of("").toAbsolutePath(); // launchers start the game in its directory
    }

    /** Copies natives/NAME out of this jar into DIR, unless an identical copy is already there. */
    private static Path unpack(String name, Path dir) throws IOException {
        byte[] data;
        try (InputStream in = MetalBootstrap.class.getResourceAsStream("/natives/" + name)) {
            if (in == null)
                throw new IOException(name + " is missing from the mcmetal jar");
            data = in.readAllBytes();
        }
        Path out = dir.resolve(name);
        if (Files.exists(out) && sha256(Files.readAllBytes(out)).equals(sha256(data)))
            return out;
        Path tmp = Files.createTempFile(dir, name, ".part");
        Files.write(tmp, data);
        Files.move(tmp, out, java.nio.file.StandardCopyOption.REPLACE_EXISTING,
                java.nio.file.StandardCopyOption.ATOMIC_MOVE);
        return out;
    }

    private static String sha256(byte[] data) throws IOException {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (java.security.NoSuchAlgorithmException e) {
            throw new IOException(e);
        }
    }

    static void log(String msg) {
        System.out.println("[mcmetal] " + msg); // the logger isn't set up this early in every launcher
    }
}
