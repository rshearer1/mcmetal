// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.irisshaders.iris;
public class Iris { public static boolean loadedIncompatiblePack() { throw new AssertionError(); } }
