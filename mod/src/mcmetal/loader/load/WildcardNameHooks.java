package mcmetal.loader.load;

import java.util.Set;

/**
 * Carry On's wildcard lists, without rebuilding every block's name for every wildcard (on unless MCMETAL_LOAD_FIXES=0;
 * see LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static fields and methods into
 * tschipp.carryon.common.config.ListHandler (names prefixed "mcmetal$"). Whenever tags load (each world start, and again
 * on the client when joining), ListHandler.addWithWildcards() matches each wildcard entry of Carry On's config
 * ("ic2:*", "minecraft:*_bed", ... 93 in Hearth & Hex's) against every block or entity id, in the order of an array
 * of the ids it takes once, turning each id into a new string every time: millions of strings, 5-9 s on the main
 * thread in the cloud test. Here the names are made once when the array is taken, and as the loop walks the array
 * each id gets its name from the same position (checked by identity: anything else gets the usual toString()).
 * No static initializer, lambdas or nested classes (they would not be copied).
 */
public final class WildcardNameHooks {
    private static Object[] keys;    // the array addWithWildcards() walks
    private static String[] names;   // names[i] = keys[i].toString()
    private static int next;         // where the walk is expected next

    private WildcardNameHooks() {
    }

    /** Stands in for registry.keySet().toArray(array) at the top of addWithWildcards(). */
    public static synchronized Object[] keys(Set<?> set, Object[] array) {
        Object[] k = set.toArray(array);
        String[] n = new String[k.length];
        for (int i = 0; i < k.length; i++)
            n[i] = k[i].toString();
        keys = k;
        names = n;
        next = 0;
        return k;
    }

    /** Stands in for key.toString() in the loop over the ids: once to match, again to add a match. */
    public static synchronized String name(Object key) {
        Object[] k = keys;
        if (k != null && k.length > 0) {
            int i = next < k.length ? next : 0;
            if (k[i] == key) {
                next = i + 1;
                return names[i];
            }
            int last = (i == 0 ? k.length : i) - 1;
            if (k[last] == key)
                return names[last];
        }
        return key.toString();
    }

    /** At the end of initConfigLists(): let the names go. */
    public static synchronized void done() {
        keys = null;
        names = null;
    }
}
