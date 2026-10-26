// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.server.packs.resources;
public interface ResourceManager {
    java.util.Optional<Resource> getResource(net.minecraft.resources.ResourceLocation location);
    java.util.Map<net.minecraft.resources.ResourceLocation, Resource> listResources(String path,
            java.util.function.Predicate<net.minecraft.resources.ResourceLocation> filter);
}
