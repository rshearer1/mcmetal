// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.common;
public class Internal {
    public static mezz.jei.common.JeiFeatures getJeiFeatures() { throw new AbstractMethodError(); }
    public static mezz.jei.common.input.IInternalKeyMappings getKeyMappings() { throw new AbstractMethodError(); }
    public static boolean hasClientRecipes() { throw new AbstractMethodError(); }
    public static void setClientFallbackRecipes(java.util.List<net.minecraft.world.item.crafting.RecipeHolder<?>> a0) { }
    public static void setRuntime(mezz.jei.api.runtime.IJeiRuntime a0) { }
}
