// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package com.mojang.blaze3d.pipeline;
public abstract class RenderTarget {
    public int width;
    public int height;
    public int getColorTextureId() { return 0; }
}
