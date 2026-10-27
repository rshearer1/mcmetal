// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.common.platform;
public interface IPlatformConfigHelper {
    public java.nio.file.Path createJeiConfigDir();
}
