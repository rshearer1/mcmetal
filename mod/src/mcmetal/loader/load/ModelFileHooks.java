package mcmetal.loader.load;

import java.util.HashSet;
import java.util.Optional;
import java.util.Set;
import java.util.function.Predicate;

import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.packs.resources.Resource;
import net.minecraft.server.packs.resources.ResourceManager;

/**
 * Entity Model Features' "is there a custom model file here?" answered from one listing of its folders (on unless
 * MCMETAL_LOAD_FIXES=0; see LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static methods and fields into EMF's EMFResourceCaching (names
 * prefixed "mcmetal$"); resourceExists() calls getResource(manager, location) where it called
 * manager.getResource(location), and clearCache() calls reset() first. EMF asks, for every entity model and every
 * folder and variant it supports, whether a .jem/.jpm/.properties file exists under emf/cem/ or optifine/cem/; almost
 * none do, and each "no" asked every one of the game's ~400 resource packs in turn (about 4 s of the render thread on
 * each F3+T in the cloud test with Hearth & Hex, 2026-10-26). The files that do exist under those two folders are listed
 * once per reload; a location in them that isn't listed is answered "not there" without the search, everything else
 * goes to the resource manager as before. If the listing fails, every question goes to the resource manager. No static
 * initializer, lambdas or nested classes (they would not be copied).
 */
public final class ModelFileHooks {
    private ModelFileHooks() {
    }

    /** ResourceLocation.toString() of every file under emf/cem/ and optifine/cem/; null until listed or if that failed. */
    private static volatile Set<String> known;
    private static volatile boolean listed;

    /** Called first thing in EMF's clearCache() (resource reloads): the next question lists the folders again. */
    private static synchronized void reset() {
        known = null;
        listed = false;
    }

    /** Stands in for manager.getResource(location) in EMF's resourceExists(). */
    private static Optional<Resource> getResource(ResourceManager manager, ResourceLocation location) {
        String path = location.getPath();
        if ((path.startsWith("emf/cem/") || path.startsWith("optifine/cem/")) && !path.endsWith(".mcmeta")) {
            Set<String> files = listed ? known : list(manager);
            if (files != null && !files.contains(location.toString()))
                return Optional.empty();
        }
        return manager.getResource(location);
    }

    private static synchronized Set<String> list(ResourceManager manager) {
        if (listed)
            return known;
        Set<String> files = new HashSet<>();
        try {
            Predicate<ResourceLocation> any = Predicate.not(Predicate.isEqual(null));
            for (ResourceLocation l : manager.listResources("emf/cem", any).keySet())
                files.add(l.toString());
            for (ResourceLocation l : manager.listResources("optifine/cem", any).keySet())
                files.add(l.toString());
        } catch (RuntimeException e) {
            files = null; // ask the resource manager every time, as EMF does
        }
        known = files;
        listed = true;
        return files;
    }
}
