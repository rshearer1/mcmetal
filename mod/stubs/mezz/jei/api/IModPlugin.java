// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.api;
public interface IModPlugin {
    public void configureJei(mezz.jei.api.runtime.IJeiFeatures a0);
    public net.minecraft.resources.ResourceLocation getPluginUid();
    public void onRuntimeAvailable(mezz.jei.api.runtime.IJeiRuntime a0);
    public void registerRuntime(mezz.jei.api.registration.IRuntimeRegistration a0);
}
