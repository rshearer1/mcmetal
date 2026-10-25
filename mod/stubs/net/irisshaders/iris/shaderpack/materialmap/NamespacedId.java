// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.irisshaders.iris.shaderpack.materialmap;
public class NamespacedId {
    public NamespacedId(String namespace, String name) { throw new AssertionError(); }
    public String getNamespace() { throw new AssertionError(); }
    public String getName() { throw new AssertionError(); }
}
