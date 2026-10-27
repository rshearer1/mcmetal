// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.resources;
public class ResourceLocation {
    public String getPath() { return null; }
    public String getNamespace() { return null; }
}
