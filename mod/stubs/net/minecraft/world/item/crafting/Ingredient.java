// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.world.item.crafting;
public final class Ingredient {
    public net.minecraft.world.item.ItemStack[] getItems() { return null; }
    public boolean isEmpty() { return false; }
    public boolean isCustom() { return false; }
}
