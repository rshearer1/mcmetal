// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.world.item.crafting;
public final class RecipeHolder<T extends Recipe<?>> { public T value() { return null; } }
