// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.caffeinemc.mods.sodium.client.util.iterator;
public interface ByteIterator { boolean hasNext(); int nextByteAsInt(); }
