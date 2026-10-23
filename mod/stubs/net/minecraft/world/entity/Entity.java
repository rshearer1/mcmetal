// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package net.minecraft.world.entity;
public class Entity { public final net.minecraft.world.phys.AABB getBoundingBox() { throw new AssertionError(); } }
