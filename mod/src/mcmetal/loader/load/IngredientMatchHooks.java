package mcmetal.loader.load;

import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.WeakHashMap;

import dev.latvian.mods.kubejs.recipe.filter.RecipeMatchContext;
import dev.latvian.mods.kubejs.recipe.match.ItemMatch;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.Ingredient;

/**
 * KubeJS's "does this recipe use item X" check, answered from a set (on unless MCMETAL_LOAD_FIXES=0; see
 * LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static fields and methods into
 * dev.latvian.mods.kubejs.recipe.component.IngredientComponent (names prefixed "mcmetal$"). A script's
 * replaceInput({input: id}, ...) asks every ingredient of every recipe whether it can be the item: KubeJS walks all
 * the items the ingredient accepts (a tag can hold hundreds) and tests each against the item. Hearth & Hex's
 * hh_unify.js does that for 46 items over ~32,000 recipes: 8.5 s of the 18.6 s recipe event in the cloud test. Here
 * an ingredient's items go into a set the first time, and later questions about the same ingredient look the item up.
 * Only for plain ingredients (an item list or a tag, not a mod's custom one) asked a non-exact question, where KubeJS's
 * answer is exactly "one of the ingredient's items is one of the match's items"; everything else, and small
 * ingredients, go the usual way. The sets are keyed by the ingredient's own item array, which the game computes once
 * and never changes, so they are never older than the game's own answer, and they go when the recipes do.
 * No static initializer, lambdas or nested classes (they would not be copied).
 */
public final class IngredientMatchHooks {
    private static Map<ItemStack[], Set<Item>> sets; // arrays compare by identity

    private IngredientMatchHooks() {
    }

    /** Stands in for match.matches(cx, in, exact) in IngredientComponent.matches(). */
    public static boolean matches(ItemMatch match, RecipeMatchContext cx, Ingredient in, boolean exact) {
        if (exact || !((Object) match instanceof Ingredient) || in.isEmpty())
            return match.matches(cx, in, exact);
        Ingredient own = (Ingredient) (Object) match; // Ingredient is an ItemMatch through KubeJS's mixin
        if (own.isCustom() || own.isEmpty())
            return match.matches(cx, in, exact);
        Set<Item> items;
        ItemStack[] ownItems;
        try {
            ItemStack[] theirs = in.getItems();
            if (theirs.length < 16)
                return match.matches(cx, in, exact);
            items = itemsOf(theirs);
            ownItems = own.getItems();
        } catch (RuntimeException e) {
            return match.matches(cx, in, exact); // KubeJS reports it in its own words
        }
        for (ItemStack s : ownItems)
            if (items.contains(s.getItem()))
                return true;
        return false;
    }

    private static synchronized Set<Item> itemsOf(ItemStack[] stacks) {
        if (sets == null)
            sets = new WeakHashMap<>();
        Set<Item> items = sets.get(stacks);
        if (items == null) {
            items = new HashSet<>();
            for (ItemStack s : stacks)
                items.add(s.getItem());
            sets.put(stacks, items);
        }
        return items;
    }
}
