// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
// The fields are private in JEI; JeiStartTransformer makes them public, and adds the two mcmetal$ fields.
package mezz.jei.library.startup;
public final class JeiStarter {
    public static volatile int mcmetal$generation;
    public static boolean mcmetal$usual;
    public StartData data;
    public java.util.List<mezz.jei.api.IModPlugin> plugins;
    public mezz.jei.library.plugins.vanilla.VanillaPlugin vanillaPlugin;
    public mezz.jei.library.config.ModIdFormatConfig modIdFormatConfig;
    public mezz.jei.library.config.ColorNameConfig colorNameConfig;
    public mezz.jei.library.config.RecipeCategorySortingConfig recipeCategorySortingConfig;
    public mezz.jei.common.config.ConfigManager configManager;
    public mezz.jei.common.config.JeiClientConfigs jeiClientConfigs;
    public java.util.List<IStopCallback> stopCallbacks;
    public boolean running;
    public void start() { }
    public void verifyClientRecipes(net.minecraft.client.Minecraft minecraft) { }
}
