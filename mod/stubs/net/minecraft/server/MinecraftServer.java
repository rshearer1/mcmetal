// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.server;
public abstract class MinecraftServer { public net.minecraft.core.RegistryAccess.Frozen registryAccess() { return null; } }
