// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package mezz.jei.library.startup;
public class StartData {
    public mezz.jei.common.network.IConnectionToServer serverConnection() { throw new AbstractMethodError(); }
}
