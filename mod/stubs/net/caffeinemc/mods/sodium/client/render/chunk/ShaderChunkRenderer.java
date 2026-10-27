// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.caffeinemc.mods.sodium.client.render.chunk;
public abstract class ShaderChunkRenderer { // protected in Sodium (DynLightHooks runs inside DefaultChunkRenderer)
    public net.caffeinemc.mods.sodium.client.gl.shader.GlProgram<?> activeProgram;
}
