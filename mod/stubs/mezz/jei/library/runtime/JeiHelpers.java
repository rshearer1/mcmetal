// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.library.runtime;
public class JeiHelpers implements mezz.jei.api.helpers.IJeiHelpers {
    public void onRuntimeStopped() { }
}
