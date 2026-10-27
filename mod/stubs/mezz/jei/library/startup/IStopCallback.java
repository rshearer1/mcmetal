// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.library.startup;
public interface IStopCallback {
    public void onRuntimeStopped();
}
