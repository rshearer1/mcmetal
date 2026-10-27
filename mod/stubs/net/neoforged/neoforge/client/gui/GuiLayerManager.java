// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.neoforged.neoforge.client.gui;
public class GuiLayerManager {
    public record NamedLayer(net.minecraft.resources.ResourceLocation name, net.minecraft.client.gui.LayeredDraw.Layer layer) {
    }
}
