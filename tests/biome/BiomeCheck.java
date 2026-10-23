import java.util.Random;
import java.util.concurrent.atomic.AtomicLong;

import mcmetal.loader.biome.BiomeHooks;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.biome.BiomeManager;

/**
 * Checks mcmetal's biome cache (mod/src/mcmetal/loader/biome/BiomeHooks) against Minecraft 1.21.1's own
 * BiomeManager.getBiome: same chosen biome cell for every position tried, on one thread and with 8 threads sharing the
 * table (on Apple silicon, whose memory ordering is weaker than x86's), then times both. Run by check.sh.
 */
public class BiomeCheck {
    static int sink;

    public static void main(String[] a) throws Exception {
        long bad = 0, n = 0;
        int[] last = new int[3];
        BiomeManager.NoiseBiomeSource rec = (x, y, z) -> { last[0] = x; last[1] = y; last[2] = z; return null; };
        Random r = new Random(42);
        long[] seeds = {0L, -1L, 1L, 42L, Long.MIN_VALUE, Long.MAX_VALUE, r.nextLong(), r.nextLong()};
        BlockPos.MutableBlockPos p = new BlockPos.MutableBlockPos();
        for (long seed : seeds) {
            BiomeManager m = new BiomeManager(rec, seed);
            for (int i = 0; i < 500_000; i++) {
                switch (i % 4) {
                    case 0 -> p.set(r.nextInt(), r.nextInt(), r.nextInt()); // anything, overflow edges too
                    case 1 -> p.set(r.nextInt(60_000_000) - 30_000_000, r.nextInt(4096) - 2048, r.nextInt(60_000_000) - 30_000_000);
                    default -> p.set(r.nextInt(200) - 100, r.nextInt(400) - 64, r.nextInt(200) - 100); // cache hits
                }
                m.getBiome(p);
                if (!same(seed, p, last))
                    bad++;
                n++;
            }
        }
        System.out.println("one thread: " + n + " lookups over " + seeds.length + " seeds, mismatches " + bad);

        AtomicLong rbad = new AtomicLong(), rn = new AtomicLong();
        Thread[] ts = new Thread[8];
        for (int t = 0; t < ts.length; t++) {
            final int id = t;
            ts[t] = new Thread(() -> {
                int[] l = new int[3];
                BiomeManager.NoiseBiomeSource src = (x, y, z) -> { l[0] = x; l[1] = y; l[2] = z; return null; };
                BiomeManager[] ms = {new BiomeManager(src, 77L), new BiomeManager(src, -5L)};
                Random rr = new Random(id);
                BlockPos.MutableBlockPos q = new BlockPos.MutableBlockPos();
                for (int i = 0; i < 2_000_000; i++) {
                    int s = rr.nextInt(2);
                    int spread = (i & 7) == 0 ? 100_000 : 48; // mostly one small shared region, some far away to evict
                    q.set(rr.nextInt(spread) - spread / 2, rr.nextInt(spread) - spread / 2, rr.nextInt(spread) - spread / 2);
                    ms[s].getBiome(q);
                    if (!same(s == 0 ? 77L : -5L, q, l))
                        rbad.incrementAndGet();
                    rn.incrementAndGet();
                }
            });
            ts[t].start();
        }
        for (Thread t : ts)
            t.join();
        System.out.println("8 threads, 2 seeds, one table: " + rn.get() + " lookups, mismatches " + rbad.get());

        time();
        if (bad != 0 || rbad.get() != 0) {
            System.out.println("FAIL: the biome cache disagrees with vanilla");
            System.exit(1);
        }
        System.out.println("OK");
    }

    static boolean same(long seed, BlockPos p, int[] vanilla) {
        int x = p.getX() - 2, y = p.getY() - 2, z = p.getZ() - 2;
        int c = BiomeHooks.corner(seed, x >> 2, y >> 2, z >> 2, (x & 3) << 4 | (y & 3) << 2 | (z & 3));
        return (x >> 2) + (c >> 2 & 1) == vanilla[0] && (y >> 2) + (c >> 1 & 1) == vanilla[1] && (z >> 2) + (c & 1) == vanilla[2];
    }

    static void time() {
        BiomeManager.NoiseBiomeSource src = (x, y, z) -> { sink += x ^ y ^ z; return null; };
        long seed = 1234567L;
        BiomeManager v = new BiomeManager(src, seed);
        String[] names = {"particles: random in a 64-block cube", "rain: same 441 columns every frame",
                "worldgen: every column of new chunks", "worst case: random anywhere"};
        int N = 1 << 16;
        for (int pat = 0; pat < names.length; pat++) {
            int[] xs = new int[N], ys = new int[N], zs = new int[N];
            Random r = new Random(pat);
            for (int i = 0; i < N; i++) {
                switch (pat) {
                    case 0 -> { xs[i] = 500 + r.nextInt(64) - 32; ys[i] = 70 + r.nextInt(64) - 32; zs[i] = -300 + r.nextInt(64) - 32; }
                    case 1 -> { int c = i % 441; xs[i] = 500 + c % 21 - 10; zs[i] = -300 + c / 21 - 10; ys[i] = 72; }
                    case 2 -> { int ch = i / 256, c = i % 256; xs[i] = (ch % 64) * 16 + (c & 15); zs[i] = (ch / 64) * 16 + (c >> 4); ys[i] = 60 + ((xs[i] * 31 + zs[i] * 17) & 15); }
                    default -> { xs[i] = r.nextInt(60_000_000) - 30_000_000; ys[i] = r.nextInt(384) - 64; zs[i] = r.nextInt(60_000_000) - 30_000_000; }
                }
            }
            BlockPos.MutableBlockPos p = new BlockPos.MutableBlockPos();
            double tv = 0, tf = 0;
            for (int rep = 0; rep < 60; rep++) {
                long t0 = System.nanoTime();
                for (int i = 0; i < N; i++)
                    v.getBiome(p.set(xs[i], ys[i], zs[i]));
                long t1 = System.nanoTime();
                for (int i = 0; i < N; i++)
                    BiomeHooks.biome(seed, src, p.set(xs[i], ys[i], zs[i]));
                long t2 = System.nanoTime();
                if (rep >= 20) {
                    tv += t1 - t0;
                    tf += t2 - t1;
                }
            }
            System.out.printf("%-38s vanilla %6.1f ns  cached %6.1f ns  (%.1fx)%n", names[pat], tv / 40 / N, tf / 40 / N, tv / tf);
        }
    }
}
