// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.library.load.registration;
public class RuntimeRegistration implements mezz.jei.api.registration.IRuntimeRegistration {
    public RuntimeRegistration(mezz.jei.api.recipe.IRecipeManager a0, mezz.jei.api.helpers.IJeiHelpers a1, mezz.jei.api.runtime.IEditModeConfig a2, mezz.jei.api.runtime.IIngredientManager a3, mezz.jei.api.recipe.transfer.IRecipeTransferManager a4, mezz.jei.api.runtime.IScreenHelper a5, mezz.jei.api.search.ISearchStorageBuilderFactory a6) { }
    public mezz.jei.api.runtime.IBookmarkOverlay getBookmarkOverlay() { throw new AbstractMethodError(); }
    public mezz.jei.api.runtime.IIngredientFilter getIngredientFilter() { throw new AbstractMethodError(); }
    public mezz.jei.api.runtime.IIngredientListOverlay getIngredientListOverlay() { throw new AbstractMethodError(); }
    public mezz.jei.api.runtime.IRecipesGui getRecipesGui() { throw new AbstractMethodError(); }
}
