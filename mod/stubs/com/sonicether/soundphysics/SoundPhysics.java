// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
// Sound Physics Remastered's fields below are private there; the code using them is copied into that class (SoundPhysicsTransformer).
package com.sonicether.soundphysics;
public class SoundPhysics {
    public static net.minecraft.sounds.SoundSource lastSoundCategory;
    public static net.minecraft.resources.ResourceLocation lastSound;
    public static int maxAuxSends;
    public SoundPhysics() { throw new AssertionError(); }
    public static net.minecraft.world.phys.Vec3 processSound(int source, double x, double y, double z, net.minecraft.sounds.SoundSource category, net.minecraft.resources.ResourceLocation sound, boolean auxOnly) { throw new AssertionError(); }
}
