// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.common.platform;
public interface IPlatformHelper {
    public mezz.jei.common.platform.IPlatformConfigHelper getConfigHelper();
}
