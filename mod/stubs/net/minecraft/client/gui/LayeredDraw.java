// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.client.gui;
public class LayeredDraw {
    public interface Layer {
        void render(GuiGraphics guiGraphics, net.minecraft.client.DeltaTracker deltaTracker);
    }
}
