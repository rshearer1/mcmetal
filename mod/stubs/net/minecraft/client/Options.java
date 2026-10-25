// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.client;
public class Options {
    public int getEffectiveRenderDistance() { return 0; }
}
