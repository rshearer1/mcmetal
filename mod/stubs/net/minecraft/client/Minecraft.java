// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.client;
public class Minecraft {
    public net.minecraft.client.gui.screens.Screen screen;
    public static Minecraft getInstance() { return null; }
    public com.mojang.blaze3d.pipeline.RenderTarget getMainRenderTarget() { return null; }
}
