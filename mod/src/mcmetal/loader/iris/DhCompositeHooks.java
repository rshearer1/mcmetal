package mcmetal.loader.iris;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.irisshaders.iris.Iris;
import net.minecraft.client.Minecraft;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL13;
import org.lwjgl.opengl.GL14;
import org.lwjgl.opengl.GL20;
import org.lwjgl.opengl.GL30;

/**
 * Distant Horizons behind shader packs that have no DH programs (SEUS PTGI), on unless MCMETAL_DH_COMPOSITE=0.
 *
 * Not used as a class: DhCompositeTransformer copies these static fields and methods into Iris's
 * IrisRenderingPipeline (names prefixed "mcmetal$") and calls dhAfterFinal() after the pack's final pass.
 * Without dh_terrain/dh_water programs Iris says "No DH shader found" and leaves DH to itself: DH still draws its
 * LODs with its own shaders into its own textures, but the pack's final pass then covers the whole screen, so the
 * far terrain never shows. Here, once the pack has finished the picture, DH's LOD picture is put back where the
 * pack drew only sky (Minecraft's depth there is still 1.0), faded into the pack's own sky colour with distance.
 * The pack's files and programs are not touched or read; this is one extra full-screen pass on top of its result.
 * Compiled against signature stubs in mod/stubs; no static initializer, lambdas or nested classes (they would not
 * be copied), so every field starts at its default value.
 */
public final class DhCompositeHooks {
    private static int dhState;                  // 0 = not set up yet, 1 = on, -1 = off (or DH not installed)
    private static MethodHandle dhTake;          // LodRenderer.mcmetal$dhTake(float[]) (DhCaptureHooks)
    private static MethodHandle dhMarkOn;        // GlGenericObjectRenderer.mcmetal$dhMarkOn() (DhGenericHooks), or null
    private static float[] dhV;
    private static float dhFog;                  // MCMETAL_DH_FOG: how much the far LODs fade into the sky, 0-2
    private static int dhProgram, dhVao, dhFbo, dhFboTex;
    private static int dhUProj, dhUFog, dhUDepth;
    private static long dhFrames;

    private DhCompositeHooks() {
    }

    private static final String VSH = """
            #version 330 core
            out vec2 uv;
            void main() {
                vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
                uv = p;
                gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
            }
            """;
    // proj: A, B, 1/P00, 1/P11 of DH's projection; fog: start, end, haze at the start, strength;
    // depth: ndc = depth * x + y, z = the empty (cleared) DH depth
    private static final String FSH = """
            #version 330 core
            uniform sampler2D dhColor;
            uniform sampler2D dhDepth;
            uniform sampler2D sceneDepth;
            uniform vec4 proj;
            uniform vec4 fog;
            uniform vec3 depth;
            in vec2 uv;
            out vec4 outColor;
            ivec2 at(sampler2D s) { return ivec2(uv * vec2(textureSize(s, 0))); }
            void main() {
                if (texelFetch(sceneDepth, at(sceneDepth), 0).r < 1.0) discard; // the pack drew something here
                float d = texelFetch(dhDepth, at(dhDepth), 0).r;
                if (d == depth.z) discard;                                     // no LOD here either: the pack's sky
                vec3 c = texelFetch(dhColor, at(dhColor), 0).rgb;
                float z = proj.y / (d * depth.x + depth.y + proj.x);           // distance along the view axis
                vec2 xy = (uv * 2.0 - 1.0) * proj.zw;
                float dist = abs(z) * sqrt(1.0 + dot(xy, xy));
                float f = clamp((dist - fog.x) / max(fog.y - fog.x, 1.0), 0.0, 1.0);
                f = clamp(mix(fog.z, 1.0, f * f * (3.0 - 2.0 * f)) * fog.w, 0.0, 1.0);
                outColor = vec4(c, 1.0 - f);                                   // blended over the pack's sky
            }
            """;

    /** After the shader pack's final pass, before the hand-off to the HUD. */
    public static void dhAfterFinal() {
        if (dhState < 0)
            return;
        if (dhState == 0)
            dhInit();
        if (dhState < 0 || !Iris.loadedIncompatiblePack())
            return;
        int got;
        try {
            got = (int) dhTake.invokeExact(dhV);
        } catch (Throwable t) {
            dhOff("could not read Distant Horizons' frame: " + t);
            return;
        }
        if (got == 0)
            return;
        try {
            if (dhMarkOn != null)
                dhMarkOn.invokeExact();
            dhDraw();
        } catch (Throwable t) {
            dhOff(t.toString());
        }
    }

    private static void dhInit() {
        String on = System.getenv("MCMETAL_DH_COMPOSITE"), fog = System.getenv("MCMETAL_DH_FOG");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_DH_COMPOSITE"); // mcmetal/options.txt
        if (fog == null)
            fog = System.getProperty("mcmetal.opt.MCMETAL_DH_FOG");
        if ("0".equals(on)) {
            dhState = -1;
            return;
        }
        dhFog = 1f;
        try {
            if (fog != null)
                dhFog = Math.max(0f, Math.min(2f, Float.parseFloat(fog.trim())));
        } catch (NumberFormatException e) {
            // keep 1
        }
        try {
            Class<?> lod = Class.forName("com.seibel.distanthorizons.core.render.renderer.LodRenderer", true,
                    DhCompositeHooks.class.getClassLoader());
            MethodType type = MethodType.methodType(int.class, float[].class);
            try {
                dhTake = MethodHandles.publicLookup().findStatic(lod, "mcmetal$dhTake", type);
            } catch (IllegalAccessException e) {
                dhTake = MethodHandles.lookup().findStatic(lod, "mcmetal$dhTake", type);
            }
        } catch (ClassNotFoundException t) {
            dhState = -1; // no Distant Horizons: nothing to do
            return;
        } catch (Throwable t) {
            dhOff("Distant Horizons is not one mcmetal patched (" + t + ")");
            return;
        }
        try { // optional: without it DH's own clouds also show on top of the pack's sky
            Class<?> generic = Class.forName("com.seibel.distanthorizons.common.render.openGl.generic.GlGenericObjectRenderer", true,
                    DhCompositeHooks.class.getClassLoader());
            dhMarkOn = MethodHandles.lookup().findStatic(generic, "mcmetal$dhMarkOn", MethodType.methodType(void.class));
        } catch (Throwable t) {
            dhMarkOn = null;
        }
        dhV = new float[9];
        dhState = 1;
    }

    private static void dhOff(String why) {
        dhState = -1;
        System.out.println("[mcmetal] Distant Horizons behind shader packs off: " + why);
    }

    private static void dhDraw() {
        Minecraft mc = Minecraft.getInstance();
        RenderTarget t = mc.getMainRenderTarget();
        int target = t.getColorTextureId(), scene = t.getDepthTextureId();
        int dhColor = (int) dhV[6], dhDepth = (int) dhV[7], flags = (int) dhV[8];
        if (target <= 0 || scene <= 0 || dhColor <= 0 || dhDepth <= 0)
            return;
        // everything Minecraft and Iris keep track of goes back exactly as it was
        int prog = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM), vao = GL11.glGetInteger(GL30.GL_VERTEX_ARRAY_BINDING);
        int drawFb = GL11.glGetInteger(GL30.GL_DRAW_FRAMEBUFFER_BINDING), readFb = GL11.glGetInteger(GL30.GL_READ_FRAMEBUFFER_BINDING);
        int active = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
        int[] vp = new int[4];
        GL11.glGetIntegerv(GL11.GL_VIEWPORT, vp);
        boolean blend = GL11.glIsEnabled(GL11.GL_BLEND), depthTest = GL11.glIsEnabled(GL11.GL_DEPTH_TEST);
        boolean cull = GL11.glIsEnabled(GL11.GL_CULL_FACE), scissor = GL11.glIsEnabled(GL11.GL_SCISSOR_TEST);
        boolean depthMask = GL11.glGetBoolean(GL11.GL_DEPTH_WRITEMASK);
        int srcRgb = GL11.glGetInteger(GL14.GL_BLEND_SRC_RGB), dstRgb = GL11.glGetInteger(GL14.GL_BLEND_DST_RGB);
        int srcA = GL11.glGetInteger(GL14.GL_BLEND_SRC_ALPHA), dstA = GL11.glGetInteger(GL14.GL_BLEND_DST_ALPHA);
        int eqRgb = GL11.glGetInteger(GL20.GL_BLEND_EQUATION_RGB), eqA = GL11.glGetInteger(GL20.GL_BLEND_EQUATION_ALPHA);
        java.nio.ByteBuffer mask = java.nio.ByteBuffer.allocateDirect(16);
        GL11.glGetBooleanv(GL11.GL_COLOR_WRITEMASK, mask);
        int[] bound = new int[3];
        for (int i = 0; i < 3; i++) {
            GL13.glActiveTexture(GL13.GL_TEXTURE0 + i);
            bound[i] = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
        }
        try {
            if (dhProgram == 0 && !dhSetUp())
                return;
            GL13.glActiveTexture(GL13.GL_TEXTURE0);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, target);
            // the colour texture's own size: mcmetal draws it smaller than the window for MetalFX
            int w = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_WIDTH);
            int h = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_HEIGHT);
            GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, dhFbo);
            if (dhFboTex != target) { // only the colour: Minecraft's depth is read, not attached
                GL30.glFramebufferTexture2D(GL30.GL_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0, GL11.GL_TEXTURE_2D, target, 0);
                dhFboTex = target;
            }
            GL11.glViewport(0, 0, w, h);
            GL11.glDisable(GL11.GL_DEPTH_TEST);
            GL11.glDisable(GL11.GL_CULL_FACE);
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            GL11.glDepthMask(false);
            GL11.glColorMask(true, true, true, false);
            GL11.glEnable(GL11.GL_BLEND);
            GL14.glBlendEquation(GL14.GL_FUNC_ADD);
            GL14.glBlendFuncSeparate(GL11.GL_SRC_ALPHA, GL11.GL_ONE_MINUS_SRC_ALPHA, GL11.GL_ZERO, GL11.GL_ONE);
            GL20.glUseProgram(dhProgram);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, dhColor);
            GL13.glActiveTexture(GL13.GL_TEXTURE1);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, dhDepth);
            GL13.glActiveTexture(GL13.GL_TEXTURE2);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, scene);
            GL20.glUniform4f(dhUProj, dhV[0], dhV[1], dhV[2], dhV[3]);
            // fog from the edge of Minecraft's own terrain out to DH's LOD radius (DH's far clip is that + 512, times sqrt 2)
            float start = mc.options.getEffectiveRenderDistance() * 16f, end = Math.max(start + 64f, dhV[5] * 0.7071f - 512f);
            GL20.glUniform4f(dhUFog, start, end, 0.15f, dhFog);
            boolean zeroToOne = (flags & 1) != 0, reverse = (flags & 2) != 0;
            GL20.glUniform3f(dhUDepth, zeroToOne ? 1f : 2f, zeroToOne ? 0f : -1f, reverse ? 0f : 1f);
            GL30.glBindVertexArray(dhVao);
            GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 3);
            if (++dhFrames == 1 || (dhFrames >= 4096 && Long.bitCount(dhFrames) == 1))
                System.out.println("[mcmetal] Distant Horizons behind the shader pack: " + dhFrames + " frames (LODs from "
                        + (int) start + " to " + (int) end + " blocks, " + w + "x" + h + ", near " + dhV[4] + ", far " + dhV[5] + ")");
        } finally {
            GL30.glBindVertexArray(vao);
            GL20.glUseProgram(prog);
            for (int i = 2; i >= 0; i--) {
                GL13.glActiveTexture(GL13.GL_TEXTURE0 + i);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound[i]);
            }
            GL13.glActiveTexture(active);
            GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, drawFb);
            GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER, readFb);
            GL11.glViewport(vp[0], vp[1], vp[2], vp[3]);
            GL20.glBlendEquationSeparate(eqRgb, eqA);
            GL14.glBlendFuncSeparate(srcRgb, dstRgb, srcA, dstA);
            if (!blend)
                GL11.glDisable(GL11.GL_BLEND);
            if (depthTest)
                GL11.glEnable(GL11.GL_DEPTH_TEST);
            if (cull)
                GL11.glEnable(GL11.GL_CULL_FACE);
            if (scissor)
                GL11.glEnable(GL11.GL_SCISSOR_TEST);
            GL11.glDepthMask(depthMask);
            GL11.glColorMask(mask.get(0) != 0, mask.get(1) != 0, mask.get(2) != 0, mask.get(3) != 0);
        }
    }

    private static boolean dhSetUp() {
        int vs = dhShader(GL20.GL_VERTEX_SHADER, VSH), fs = dhShader(GL20.GL_FRAGMENT_SHADER, FSH);
        if (vs == 0 || fs == 0)
            return false;
        int p = GL20.glCreateProgram();
        GL20.glAttachShader(p, vs);
        GL20.glAttachShader(p, fs);
        GL30.glBindFragDataLocation(p, 0, "outColor");
        GL20.glLinkProgram(p);
        GL20.glDeleteShader(vs);
        GL20.glDeleteShader(fs);
        if (GL20.glGetProgrami(p, GL20.GL_LINK_STATUS) == 0) {
            dhOff("the composite program did not link: " + GL20.glGetProgramInfoLog(p));
            GL20.glDeleteProgram(p);
            return false;
        }
        GL20.glUseProgram(p);
        GL20.glUniform1i(GL20.glGetUniformLocation(p, "dhColor"), 0);
        GL20.glUniform1i(GL20.glGetUniformLocation(p, "dhDepth"), 1);
        GL20.glUniform1i(GL20.glGetUniformLocation(p, "sceneDepth"), 2);
        dhUProj = GL20.glGetUniformLocation(p, "proj");
        dhUFog = GL20.glGetUniformLocation(p, "fog");
        dhUDepth = GL20.glGetUniformLocation(p, "depth");
        dhProgram = p;
        dhVao = GL30.glGenVertexArrays();
        dhFbo = GL30.glGenFramebuffers();
        return true;
    }

    private static int dhShader(int type, String src) {
        int s = GL20.glCreateShader(type);
        GL20.glShaderSource(s, src);
        GL20.glCompileShader(s);
        if (GL20.glGetShaderi(s, GL20.GL_COMPILE_STATUS) == 0) {
            dhOff("the composite shader did not compile: " + GL20.glGetShaderInfoLog(s));
            GL20.glDeleteShader(s);
            return 0;
        }
        return s;
    }
}
