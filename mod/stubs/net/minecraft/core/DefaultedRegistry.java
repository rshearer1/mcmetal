// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.core;
public interface DefaultedRegistry<T> extends Iterable<T> {
    boolean containsKey(net.minecraft.resources.ResourceLocation id);
    T get(net.minecraft.resources.ResourceLocation id);
}
