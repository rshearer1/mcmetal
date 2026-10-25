package mcmetal.loader.load;

import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.world.item.Item;
import net.minecraft.world.level.ItemLike;

/**
 * Create's "is this new stack a clipboard?" check, answered by comparing items (on unless MCMETAL_LOAD_FIXES=0; see
 * LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static fields and methods into Create's
 * com.simibubi.create.foundation.mixin.ItemStackMixin (names prefixed "mcmetal$"), and Mixin then copies them into
 * ItemStack with the rest of that mixin. Create's mixin runs in every ItemStack constructor and asked
 * "BuiltInRegistries.ITEM.getKey(item.asItem()).equals(CLIPBOARD_ID)": a registry lookup and a walk to the item's id
 * for every stack made, and JEI makes millions of stacks while it starts after joining a world (a quarter of JEI's
 * start in the cloud test). The clipboard item is looked up once by its id instead, and each stack compares its item
 * with it. Same answer: the registry holds one item under that id. Until that item is registered no stack can be one.
 * No static initializer, lambdas or nested classes (they would not be copied).
 */
public final class ClipboardHooks {
    private static Item clipboard; // the item registered as Create's clipboard, once it is

    private ClipboardHooks() {
    }

    /** Stands in for "BuiltInRegistries.ITEM.getKey(item.asItem()).equals(id)". */
    private static boolean isClipboard(ItemLike item, ResourceLocation id) {
        Item c = clipboard;
        if (c == null) {
            if (!BuiltInRegistries.ITEM.containsKey(id))
                return false;
            c = clipboard = BuiltInRegistries.ITEM.get(id);
        }
        return item.asItem() == c;
    }
}
