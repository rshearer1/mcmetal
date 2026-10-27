// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.client.multiplayer;
public class ClientLevel {
    public net.minecraft.world.item.crafting.RecipeManager getRecipeManager() { throw new AbstractMethodError(); }
    public net.minecraft.core.RegistryAccess registryAccess() { throw new AbstractMethodError(); }
}
