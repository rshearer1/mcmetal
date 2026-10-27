// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.library.startup;
public class PluginAwareJeiFeatures implements mezz.jei.api.runtime.IJeiFeatures {
    public PluginAwareJeiFeatures(mezz.jei.api.runtime.IJeiFeatures a0, mezz.jei.api.IModPlugin a1) { }
}
