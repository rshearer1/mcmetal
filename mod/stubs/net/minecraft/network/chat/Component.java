// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.network.chat;
public interface Component {
    String getString();
    ComponentContents getContents();
    java.util.List<Component> getSiblings();
}
