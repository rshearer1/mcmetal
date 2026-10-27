// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.library.ingredients;
public class IngredientManager implements mezz.jei.api.runtime.IIngredientManager {
    public void onRuntimeStopped() { }
}
