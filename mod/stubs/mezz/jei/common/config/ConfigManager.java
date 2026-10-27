// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.common.config;
public class ConfigManager implements mezz.jei.api.runtime.config.IJeiConfigManager {
    public void onJeiStarted() { }
}
