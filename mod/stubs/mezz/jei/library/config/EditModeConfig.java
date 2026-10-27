// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.library.config;
public class EditModeConfig implements mezz.jei.api.runtime.IEditModeConfig {
    public EditModeConfig(mezz.jei.library.config.EditModeConfig.ISerializer a0, mezz.jei.api.runtime.IIngredientManager a1) { }
    public interface ISerializer { }
    public static class FileSerializer implements ISerializer {
        public FileSerializer(java.nio.file.Path a0, net.minecraft.core.RegistryAccess a1, mezz.jei.api.helpers.ICodecHelper a2) { }
    }
}
