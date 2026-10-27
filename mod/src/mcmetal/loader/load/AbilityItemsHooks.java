package mcmetal.loader.load;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Stream;

import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.neoforged.neoforge.common.ItemAbility;

/**
 * Farmer's Delight's "any tool that can do X" ingredient (any knife, any axe), resolved once per ability (on unless
 * MCMETAL_LOAD_FIXES=0; see LoadSpeedTransformer). Idea from Nitro (MIT, github.com/TinsleyDevers/Nitro, fix 16);
 * this is our own code.
 *
 * Not used as a class: LoadSpeedTransformer copies these static fields and methods into
 * vectorwing.farmersdelight.common.crafting.ingredient.ItemAbilityIngredient (names prefixed "mcmetal$"). Each such
 * ingredient worked out its items by making a stack of every registered item and asking it canPerformAction(ability),
 * and every recipe has its own ingredient object: one walk of the whole item registry per cutting-board recipe, each
 * time recipes load and again when JEI and KubeJS ask. The answer only depends on the ability (a fresh stack of an
 * item always answers the same), so the matching items are found once per ability and each ingredient gets fresh
 * stacks of them, in registry order as before. No static initializer, lambdas or nested classes (they would not be
 * copied).
 */
public final class AbilityItemsHooks {
    private static Map<ItemAbility, List<Item>> items; // ability -> the items whose fresh stack can do it

    private AbilityItemsHooks() {
    }

    /** What dissolve() would have put in itemStacks: fresh stacks of every item that can do the ability. */
    public static Stream<ItemStack> stacks(ItemAbility ability) {
        List<Item> found = itemsFor(ability);
        List<ItemStack> out = new ArrayList<>(found.size());
        for (Item item : found)
            out.add(new ItemStack(item));
        return out.stream();
    }

    private static synchronized List<Item> itemsFor(ItemAbility ability) {
        if (items == null) // recipes only load once the item registry is frozen, so the answers keep
            items = new HashMap<>();
        List<Item> found = items.get(ability);
        if (found == null) {
            found = new ArrayList<>();
            for (Item item : BuiltInRegistries.ITEM)
                if (new ItemStack(item).canPerformAction(ability))
                    found.add(item);
            items.put(ability, found);
        }
        return found;
    }
}
