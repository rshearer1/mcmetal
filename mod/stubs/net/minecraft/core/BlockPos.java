// Compile-only stand-in (signatures only) so mod/src can be compiled without Minecraft; never packaged.
package net.minecraft.core;
public class BlockPos {
    public int getX() { return 0; }
    public int getY() { return 0; }
    public int getZ() { return 0; }
}
