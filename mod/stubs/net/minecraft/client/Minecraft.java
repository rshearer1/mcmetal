// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.client;
public class Minecraft {
    public net.minecraft.client.gui.screens.Screen screen;
    public Options options;
    public net.minecraft.client.multiplayer.ClientLevel level;
    public static Minecraft getInstance() { return null; }
    public void execute(Runnable task) { }
    public boolean isSameThread() { return false; }
    public com.mojang.blaze3d.pipeline.RenderTarget getMainRenderTarget() { return null; }
}
