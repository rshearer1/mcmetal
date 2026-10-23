// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.world.item;
public final class ItemStack {
    public Item getItem() { return null; }
    public boolean is(net.minecraft.tags.TagKey<Item> tag) { return false; }
}
