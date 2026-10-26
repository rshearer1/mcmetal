// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.network.chat.contents;
public class TranslatableContents implements net.minecraft.network.chat.ComponentContents {
    public String getKey() { return null; }
    public Object[] getArgs() { return null; }
}
