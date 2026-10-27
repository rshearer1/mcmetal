// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.world.item.crafting;
public class RecipeManager {
    public java.util.Collection<RecipeHolder<?>> getRecipes() { return null; }
    public void replaceRecipes(Iterable<RecipeHolder<?>> recipes) { }
}
