// Compile-only stand-in (signatures only) so mod/src can be compiled without the real game; never packaged.
package net.minecraft.core;
public class NonNullList<E> extends java.util.AbstractList<E> {
    public E get(int i) { return null; }
    public int size() { return 0; }
}
