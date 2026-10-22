// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.irisshaders.iris.shadows;
public class ShadowRenderingState { public static boolean areShadowsCurrentlyBeingRendered() { throw new AssertionError(); } }
