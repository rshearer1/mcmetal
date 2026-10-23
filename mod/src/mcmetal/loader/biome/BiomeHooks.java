package mcmetal.loader.biome;

import java.util.concurrent.atomic.AtomicReferenceArray;

import net.minecraft.core.BlockPos;
import net.minecraft.core.Holder;
import net.minecraft.world.level.biome.BiomeManager;

/**
 * Faster BiomeManager.getBiome(BlockPos), Java side (on unless MCMETAL_BIOME_CACHE=0; see BiomeTransformer).
 *
 * Not used as a class: BiomeTransformer copies these static fields and methods into Minecraft's
 * net.minecraft.world.level.biome.BiomeManager (names prefixed "mcmetal$") and starts getBiome(pos) with
 * `Holder h = biome(biomeZoomSeed, noiseBiomeSource, pos); if (h != null) return h;`.
 *
 * getBiome blurs biome borders: it looks at the 8 corners of the 4x4x4 block cell around the position, gives each a
 * random-looking nudge hashed from the world seed and the corner (8 rounds of a 64-bit LCG plus 3 floorMods per
 * corner), and takes the biome of the nearest one. Particles, rain, fog, ambient-sound mods and world generation
 * call it thousands of times a frame; with the Hearth & Hex mods it was ~30% of the render thread's Java time
 * (M3 run J2) and it is hot on the world-generation threads when flying into new land (J1).
 * Which corner wins depends only on the seed, the cell and the block's place inside the cell, never on the world's
 * contents, so it can be kept: the first lookup in a cell works out the winner for all 64 blocks in it (the 8 corner
 * nudges once, then 512 cheap distance sums done with exactly vanilla's double arithmetic and tie rule) and later
 * lookups just read 4 bits. The biome itself is still fetched live from noiseBiomeSource every time, so loaded
 * chunks, /fillbiome and new dimensions are seen at once.
 *
 * Cells live in a fixed table of SLOTS entries (a new cell in a taken slot replaces the old one); each entry is an
 * immutable long[7] {seed, x<<32|z, y, 4 words of 16 x 4-bit winners}, published with release/acquire so the
 * world-generation threads and the render thread can share it without locks. No static initializer, lambdas or
 * nested classes (they would not be copied), so the table is made on first use.
 */
public final class BiomeHooks {
    private static final int SLOTS = 16384; // a compile-time constant, inlined: no static initializer needed
    private static AtomicReferenceArray<long[]> cells;

    private BiomeHooks() {
    }

    /** Stands in for the body of getBiome(pos). */
    public static Holder<?> biome(long seed, BiomeManager.NoiseBiomeSource source, BlockPos pos) {
        int x = pos.getX() - 2, y = pos.getY() - 2, z = pos.getZ() - 2;
        int qx = x >> 2, qy = y >> 2, qz = z >> 2;
        int c = corner(seed, qx, qy, qz, (x & 3) << 4 | (y & 3) << 2 | (z & 3));
        return source.getNoiseBiome(qx + (c >> 2 & 1), qy + (c >> 1 & 1), qz + (c & 1));
    }

    /** The winning corner (bit 2 = x+1, bit 1 = y+1, bit 0 = z+1) for block `n` (x<<4 | y<<2 | z, 0-3 each) of cell q. */
    public static int corner(long seed, int qx, int qy, int qz, int n) {
        AtomicReferenceArray<long[]> t = cells;
        if (t == null)
            cells = t = new AtomicReferenceArray<>(SLOTS); // two threads racing here only lose a few entries
        int h = qx * 0x9E3779B1 ^ qy * 0x85EBCA77 ^ qz * 0xC2B2AE3D;
        int slot = (h ^ h >>> 15) & (SLOTS - 1);
        long xz = (long) qx << 32 | (qz & 0xFFFFFFFFL);
        long[] e = t.getAcquire(slot);
        if (e == null || e[0] != seed || e[1] != xz || e[2] != qy) {
            e = fill(seed, qx, qy, qz, xz);
            t.setRelease(slot, e);
        }
        int w = 27 + (n >> 4), shift = (n & 15) << 2;
        int known = (int) (e[w] >>> shift) & 15;
        if (known != 0)
            return known - 1;
        // vanilla's loop, with the corner nudges read instead of hashed
        double d0 = (double) (n >> 4) / 4.0, d1 = (double) (n >> 2 & 3) / 4.0, d2 = (double) (n & 3) / 4.0;
        int best = 0;
        double bestDist = Double.POSITIVE_INFINITY;
        for (int k = 0; k < 8; k++) {
            double d4 = (k & 4) == 0 ? d0 : d0 - 1.0;
            double d5 = (k & 2) == 0 ? d1 : d1 - 1.0;
            double d6 = (k & 1) == 0 ? d2 : d2 - 1.0;
            double a = d6 + Double.longBitsToDouble(e[5 + 3 * k]), b = d5 + Double.longBitsToDouble(e[4 + 3 * k]),
                    c = d4 + Double.longBitsToDouble(e[3 + 3 * k]);
            double dist = a * a + b * b + c * c; // vanilla: square(z) + square(y) + square(x), in that order
            if (bestDist > dist) {
                best = k;
                bestDist = dist;
            }
        }
        // remember it. Racing threads may drop each other's notes (a stale word written back), never corrupt one:
        // a 4-bit note is only ever 0 (not known yet) or the right answer + 1
        e[w] |= (long) (best + 1) << shift;
        return best;
    }

    /**
     * A cell entry: {seed, x<<32|z, y, then corner k's x, y, z nudges (double bits) at 3+3k..5+3k with k in vanilla's
     * bit order, then 4 words of 16 x 4-bit notes: winning corner + 1 for each block of the cell, 0 until worked out}.
     */
    public static long[] fill(long seed, int qx, int qy, int qz, long xz) {
        long[] e = new long[31];
        e[0] = seed;
        e[1] = xz;
        e[2] = qy;
        for (int k = 0; k < 8; k++) {
            long cx = qx + (k >> 2 & 1), cy = qy + (k >> 1 & 1), cz = qz + (k & 1);
            long s = next(seed, cx);
            s = next(s, cy);
            s = next(s, cz);
            s = next(s, cx);
            s = next(s, cy);
            s = next(s, cz);
            e[3 + 3 * k] = Double.doubleToRawLongBits(fiddle(s));
            s = next(s, seed);
            e[4 + 3 * k] = Double.doubleToRawLongBits(fiddle(s));
            s = next(s, seed);
            e[5 + 3 * k] = Double.doubleToRawLongBits(fiddle(s));
        }
        return e;
    }

    /** LinearCongruentialGenerator.next. */
    public static long next(long s, long add) {
        s *= s * 6364136223846793005L + 1442695040888963407L;
        return s + add;
    }

    /** BiomeManager.getFiddle. */
    public static double fiddle(long s) {
        double d = (double) Math.floorMod(s >> 24, 1024) / 1024.0;
        return (d - 0.5) * 0.9;
    }
}
