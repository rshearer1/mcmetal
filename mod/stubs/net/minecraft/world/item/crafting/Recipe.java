// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.world.item.crafting;
public interface Recipe<T> {
    RecipeType<?> getType();
    net.minecraft.world.item.ItemStack getResultItem(net.minecraft.core.HolderLookup.Provider registries);
    net.minecraft.core.NonNullList<Ingredient> getIngredients();
}
