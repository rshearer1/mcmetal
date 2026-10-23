package mcmetal.loader.load;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;

import net.minecraft.core.HolderLookup;
import net.minecraft.server.MinecraftServer;
import net.minecraft.tags.ItemTags;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.crafting.Ingredient;
import net.minecraft.world.item.crafting.Recipe;
import net.minecraft.world.item.crafting.RecipeHolder;
import net.minecraft.world.item.crafting.RecipeManager;
import net.minecraft.world.item.crafting.RecipeType;

/**
 * Hexerei's woodcutter list, built from an index (on unless MCMETAL_LOAD_FIXES=0; see LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static fields and methods into
 * net.joefoxe.hexerei.data.recipes.WoodcutterRecipes (names prefixed "mcmetal$"). Every time a world starts,
 * WoodcutterRecipes.createRecipes() walks all planks, and for each one every recipe in the game, asking each recipe
 * for its result and that result for ten wooden tags (boats, signs, slabs, ... pressure plates); a recipe only counts
 * when the plank is one of its ingredients. With Hearth & Hex's 32,413 recipes that was 198 s of the cloud test's
 * start into an existing world (9 s with this), on the server thread, before the player could join. Here each recipe is looked at once: those whose
 * result has one of the ten tags are listed under every item among their ingredients, in the recipe manager's order,
 * and the plank loop gets only the plank's own list in place of getRecipes(). Recipes left out are exactly the ones
 * the loop would have skipped, so the woodcutter recipes, and their order, come out the same.
 * No static initializer, lambdas or nested classes (they would not be copied).
 */
public final class WoodcutterHooks {
    private static HolderLookup.Provider registries;
    private static Collection<RecipeHolder<?>> indexed;            // the getRecipes() the index was made from
    private static Map<Item, List<RecipeHolder<?>>> byIngredient;

    private WoodcutterHooks() {
    }

    /** At the top of createRecipes(server): drop the last world's index. */
    public static void begin(MinecraftServer server) {
        registries = server.registryAccess();
        indexed = null;
        byIngredient = null;
    }

    /** Stands in for manager.getRecipes() in the plank loop: the recipes that can give this plank a woodcutter recipe. */
    public static Collection<RecipeHolder<?>> recipesFor(RecipeManager manager, Item plank) {
        Collection<RecipeHolder<?>> all = manager.getRecipes();
        if (byIngredient == null || indexed != all) {
            Map<Item, List<RecipeHolder<?>>> index = new IdentityHashMap<>();
            for (RecipeHolder<?> holder : all) {
                Recipe<?> recipe = holder.value();
                if (recipe.getType() != RecipeType.CRAFTING || !wooden(recipe.getResultItem(registries)))
                    continue;
                List<Ingredient> ingredients = recipe.getIngredients();
                for (int i = 0; i < ingredients.size(); i++)
                    for (ItemStack stack : ingredients.get(i).getItems()) {
                        List<RecipeHolder<?>> list = index.get(stack.getItem());
                        if (list == null) {
                            list = new ArrayList<>();
                            index.put(stack.getItem(), list);
                        }
                        if (list.isEmpty() || list.get(list.size() - 1) != holder) // once per recipe
                            list.add(holder);
                    }
            }
            indexed = all;
            byIngredient = index;
        }
        List<RecipeHolder<?>> list = byIngredient.get(plank);
        return list != null ? list : Collections.emptyList();
    }

    /** The tags createRecipes() checks a recipe's result for, in its plank loop. */
    private static boolean wooden(ItemStack out) {
        return out.is(ItemTags.BOATS) || out.is(ItemTags.SIGNS) || out.is(ItemTags.WOODEN_SLABS)
                || out.is(ItemTags.WOODEN_STAIRS) || out.is(ItemTags.WOODEN_DOORS) || out.is(ItemTags.WOODEN_TRAPDOORS)
                || out.is(ItemTags.WOODEN_BUTTONS) || out.is(ItemTags.WOODEN_FENCES) || out.is(ItemTags.FENCE_GATES)
                || out.is(ItemTags.WOODEN_PRESSURE_PLATES);
    }
}
