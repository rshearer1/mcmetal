package mcmetal.loader.load;

import java.util.Map;

import net.minecraft.world.level.block.state.properties.Property;

/**
 * The name of a block state's model ("facing=north,lit=true"), built without an entry set (on unless
 * MCMETAL_LOAD_FIXES=0; see LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies this static method into
 * net.minecraft.client.renderer.block.BlockModelShaper (name prefixed "mcmetal$") and makes statePropertiesToString()
 * return it. Vanilla walks state.getValues().entrySet(); with FerriteCore that map's entrySet() builds a new set of new
 * entries every time (an ObjectArraySet whose every add() compares with the entries already in it). The model loaders
 * ask this for every block state of every block, several times per resource reload (Puzzles Lib twice, ModernFix,
 * Diagonal Blocks...), and it was a large share of the M3's one busy model loading thread before the title screen
 * (LT2, 2026-10-25). The same names come from keySet() (FerriteCore keeps it ready, in the order its entry set uses) and
 * get(), with nothing else built. No static initializer, lambdas or nested classes (they would not be copied).
 */
public final class StateNameHooks {
    private StateNameHooks() {
    }

    /** Stands in for statePropertiesToString(map): "name=value" for each property, comma separated, in keySet order. */
    @SuppressWarnings({"rawtypes", "unchecked"})
    private static String propertiesString(Map<Property<?>, Comparable<?>> map) {
        StringBuilder s = new StringBuilder();
        for (Property p : map.keySet()) {
            if (s.length() != 0)
                s.append(',');
            s.append(p.getName()).append('=').append(p.getName((Comparable) map.get(p)));
        }
        return s.toString();
    }
}
