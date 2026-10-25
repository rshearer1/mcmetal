// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.world.level.block.state.properties;
public abstract class Property<T extends Comparable<T>> {
    public String getName() { return null; }
    public abstract String getName(T value);
}
