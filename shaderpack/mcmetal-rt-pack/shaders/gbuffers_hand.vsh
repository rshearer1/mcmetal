#version 330 compatibility
// The held item (and First-person Model's body, which it draws as part of the hand): lit right here and kept as is
// by deferred4, because Iris can run this program twice, before the deferred passes and again after them (the hand
// pass's second half). A G-buffer write in that second run landed unlit on the finished picture
#define VSH
#define FORWARD
#define KEEP_MATERIAL
#define MATERIAL MAT_HAND
#include "/lib/gbuffer.glsl"
