// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.minecraft.world.phys;
public class AABB {
    // set in a constructor, not "= 0": a final field with a constant initializer would be inlined as 0 by javac
    public final double minX, minY, minZ, maxX, maxY, maxZ;
    public AABB(double x1, double y1, double z1, double x2, double y2, double z2) {
        minX = x1; minY = y1; minZ = z1; maxX = x2; maxY = y2; maxZ = z2;
    }
}
