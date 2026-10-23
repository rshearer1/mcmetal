// Compile-only stand-in (signatures only) so mod/src can be compiled without Minecraft; never packaged.
package net.minecraft.world.level.biome;
public class BiomeManager {
    public interface NoiseBiomeSource {
        net.minecraft.core.Holder<?> getNoiseBiome(int x, int y, int z);
    }
}
