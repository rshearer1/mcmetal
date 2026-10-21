// Every non-sampler uniform the pack uses (declared once per program, here).
uniform mat4 gbufferModelView, gbufferModelViewInverse, gbufferProjection, gbufferProjectionInverse;
uniform mat4 shadowModelView, shadowProjection;
uniform vec3 sunPosition, moonPosition, shadowLightPosition, upPosition, cameraPosition;
uniform float rainStrength, wetness, far, near, viewWidth, viewHeight, frameTimeCounter;
uniform float nightVision, blindness, darknessFactor;
uniform int frameCounter, isEyeInWater, heldBlockLightValue, heldBlockLightValue2, renderStage, moonPhase, worldTime;
uniform ivec2 eyeBrightnessSmooth;
uniform vec4 entityColor;
