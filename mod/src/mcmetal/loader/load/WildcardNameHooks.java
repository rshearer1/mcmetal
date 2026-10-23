package mcmetal.loader.load;

import java.util.IdentityHashMap;
import java.util.Map;

/**
 * Carry On's wildcard lists, without rebuilding every block's name for every wildcard (on unless MCMETAL_LOAD_FIXES=0;
 * see LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static fields and methods into
 * tschipp.carryon.common.config.ListHandler (names prefixed "mcmetal$"). Whenever tags load (each world start, and again
 * on the client when joining), ListHandler.initConfigLists() matches each wildcard entry of Carry On's config ("ic2:*",
 * "minecraft:*_bed", ... 93 in Hearth & Hex's) against every block or entity id, turning each id into a new string
 * every time: ~3.7 million strings, 5-9 s on the main thread in the cloud test. An id's string never changes, so each
 * is made once and reused until the lists are built. No static initializer, lambdas or nested classes (they would not
 * be copied).
 */
public final class WildcardNameHooks {
    private static Map<Object, String> names;

    private WildcardNameHooks() {
    }

    /** Stands in for key.toString() in addWithWildcards(). */
    public static synchronized String name(Object key) {
        if (names == null)
            names = new IdentityHashMap<>();
        String s = names.get(key);
        if (s == null) {
            s = key.toString();
            names.put(key, s);
        }
        return s;
    }

    /** At the end of initConfigLists(): let the names go. */
    public static synchronized void done() {
        names = null;
    }
}
