// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package dev.latvian.mods.kubejs.recipe.match;
public interface ItemMatch {
    boolean matches(dev.latvian.mods.kubejs.recipe.filter.RecipeMatchContext cx, net.minecraft.world.item.crafting.Ingredient in, boolean exact);
}
