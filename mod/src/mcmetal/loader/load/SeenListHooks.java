package mcmetal.loader.load;

import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Vegan Delight's "already looked at" list, answered from a set (on unless MCMETAL_LOAD_FIXES=0; see
 * LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static fields and methods into
 * net.player005.vegandelightfabric.labels.VeganLabels (names prefixed "mcmetal$"). Every time recipes load (each world
 * start), VeganLabels.initialize() walks every item's recipes to guess which items are vegan, keeping the items it
 * has seen in an ArrayList and asking it contains() before each one: with ~57,000 items that is a scan of a growing
 * list per question (16-19 s in the cloud test, while the world loads). The list's add() and contains() now also go
 * through a HashSet of the same items, so the answers (equals(), like the list's) are the same, only quicker.
 * The list is still filled as before. No static initializer, lambdas or nested classes (they would not be copied).
 */
public final class SeenListHooks {
    private static List<?> list; // the list the set mirrors
    private static Set<Object> seen;
    private static int size;     // the list's size when the set last matched it

    private SeenListHooks() {
    }

    /** Stands in for list.add(item). */
    public static synchronized boolean add(List<Object> to, Object item) {
        mirror(to);
        seen.add(item);
        boolean added = to.add(item);
        size = to.size();
        return added;
    }

    /** Stands in for list.contains(item). */
    public static synchronized boolean contains(List<?> in, Object item) {
        mirror(in);
        return seen.contains(item);
    }

    /** At the end of initialize(): let the set go. */
    public static synchronized void done() {
        list = null;
        seen = null;
    }

    private static void mirror(List<?> l) {
        if (l != list || seen == null || l.size() != size) { // another list, or changed behind our back: start from what it holds
            list = l;
            seen = new HashSet<>(l);
            size = l.size();
        }
    }
}
