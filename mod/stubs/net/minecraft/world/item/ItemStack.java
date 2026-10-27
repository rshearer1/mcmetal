// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.world.item;
public final class ItemStack {
    public ItemStack(net.minecraft.world.level.ItemLike item) { }
    public Item getItem() { return null; }
    public boolean is(net.minecraft.tags.TagKey<Item> tag) { return false; }
    public boolean canPerformAction(net.neoforged.neoforge.common.ItemAbility ability) { return false; }
}
