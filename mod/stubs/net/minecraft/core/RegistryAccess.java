// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.core;
public interface RegistryAccess extends HolderLookup.Provider { interface Frozen extends RegistryAccess { } }
