package mcmetal.loader.hud;

import java.util.IdentityHashMap;
import java.util.List;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphics;
import net.minecraft.resources.ResourceLocation;
import net.neoforged.neoforge.client.gui.GuiLayerManager;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL13;
import org.lwjgl.opengl.GL14;
import org.lwjgl.opengl.GL15;
import org.lwjgl.opengl.GL20;
import org.lwjgl.opengl.GL30;

/**
 * The HUD cache (on unless MCMETAL_HUD_CACHE=0; see HudCacheTransformer): the HUD is drawn MCMETAL_HUD_FPS times a
 * second (default 30) into a texture of its own, and every frame lays that texture over the world.
 *
 * Not used as a class: HudCacheTransformer copies these static fields and methods into NeoForge's GuiLayerManager
 * (names prefixed "mcmetal$"). In GuiLayerManager.renderInner(), start() runs first, every layer's render call goes
 * goes through skip() first, and end() runs last.
 * The HUD is redrawn in full every frame: the hotbar with its item icons, health and food, Xaero's minimap (~150 draws
 * a frame on its own), Jade's tooltip, chat, effects. Here the layers up to and including the crosshair (the
 * vignette, pumpkin and portal overlays, which darken or invert the world under them, and the crosshair) still draw
 * straight onto the world every frame; the layers after it draw into the HUD texture only on redraw frames, and the
 * frames in between only put the texture back. mcmetal's GL layer makes the texture's alpha add up the way "over"
 * blending does (glHint MGL_HINT_HUD_FBO, see mgl_draw.c), so laying it over the world with (ONE, ONE_MINUS_SRC_ALPHA)
 * gives what drawing the layers there directly would have.
 * Compiled against signature stubs in mod/stubs; no static initializer, lambdas or nested classes (they would not
 * be copied), so every field starts at its default value.
 */
public final class HudHooks {
    private static final int HINT_HUD_FBO = 0x6D63; // core/mgl_state.h MGL_HINT_HUD_FBO

    private static int state;              // 0 = settings not read yet, 1 = on, -1 = off
    private static long interval;          // ns between HUD redraws
    private static List<?> list;           // the game's HUD layers (Gui's GuiLayerManager)
    private static IdentityHashMap<Object, Integer> position; // each layer's place in the list
    private static int count;
    private static boolean active, usable; // this renderInner call is the game's HUD and the cache is on
    private static int crosshair;          // place of minecraft:crosshair: layers after it are cached
    private static boolean redraw, drawing;
    private static long madeAt;
    private static int fbo, tex, depth, forW, forH;
    private static int prog, vao;
    private static long frames, kept;      // HUD frames, and those that reused the texture (for the log)

    private HudHooks() {
    }

    /** First thing in GuiLayerManager.renderInner: decide whether the cached layers are drawn this frame. */
    public static void start(List<?> layers, GuiGraphics g) {
        if (state == 0)
            init(layers);
        drawing = false;
        redraw = false;
        active = state > 0 && layers == list; // only the game's own HUD, not a mod's own layer list
        if (!active)
            return;
        if (layers.size() != count)
            index(layers); // a mod added layers late
        RenderTarget t = Minecraft.getInstance().getMainRenderTarget();
        if (forW != t.width || forH != t.height) {
            forW = t.width;
            forH = t.height;
            usable = make(t);
            redraw = true;
        } else {
            redraw = System.nanoTime() - madeAt >= interval;
        }
        if (!usable) {
            active = false; // e.g. MetalFX draws the world smaller than the window: tried again on a resize
            return;
        }
        if (++frames >= 1024 && Long.bitCount(frames) == 1) // now and then: how much it saves
            System.out.println("[mcmetal] HUD cache: " + kept + " of " + frames + " frames reused the HUD");
        if (!redraw)
            kept++;
    }

    /**
     * Before each layer (and before NeoForge's RenderGuiLayerEvent.Pre for it): true skips the layer, its events
     * included, because it is in the HUD texture already. The first layer drawn into the texture switches to it.
     */
    public static boolean skip(Object named, GuiGraphics g) {
        if (!active)
            return false;
        Integer at = position.get(named);
        if (at == null || at <= crosshair)
            return false; // drawn on the world every frame
        if (!redraw)
            return true;
        if (!drawing) {
            g.flush(); // what earlier layers queued belongs on the world
            begin();
            drawing = true;
        }
        return false;
    }

    /** Last thing in GuiLayerManager.renderInner: finish a redraw, and lay the HUD texture over the world. */
    public static void end(GuiGraphics g) {
        if (!active)
            return;
        if (redraw) {
            if (drawing)
                g.flush();
            else
                begin(); // no cached layer drew this frame: an empty texture
            finish();
            drawing = false;
            madeAt = System.nanoTime();
        }
        composite();
    }

    private static void init(List<?> layers) {
        String on = System.getenv("MCMETAL_HUD_CACHE"), fps = System.getenv("MCMETAL_HUD_FPS");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_HUD_CACHE"); // mcmetal/options.txt
        if (fps == null)
            fps = System.getProperty("mcmetal.opt.MCMETAL_HUD_FPS");
        int n = 30;
        try {
            if (fps != null)
                n = Integer.parseInt(fps.trim());
        } catch (NumberFormatException e) {
            // keep 30
        }
        list = layers;
        index(layers);
        state = "0".equals(on) || n <= 0 ? -1 : 1;
        if (state > 0 && crosshair == Integer.MAX_VALUE)
            System.out.println("[mcmetal] HUD cache: no crosshair layer to split the HUD at, every layer drawn live");
        interval = n <= 0 ? 0 : 1_000_000_000L / n;
        System.out.println("[mcmetal] HUD cache " + (state > 0 ? "on: " + (layers.size() - Math.min(crosshair, layers.size() - 1) - 1) + " of "
                + layers.size() + " HUD layers drawn " + n + " times a second" : "off"));
    }

    /** Each layer's place in the list, and the crosshair's. */
    private static void index(List<?> layers) {
        crosshair = -1;
        position = new IdentityHashMap<>();
        for (int i = 0; i < layers.size(); i++) {
            GuiLayerManager.NamedLayer l = (GuiLayerManager.NamedLayer) layers.get(i);
            ResourceLocation name = l.name();
            position.put(l, i);
            if ("minecraft".equals(name.getNamespace()) && "crosshair".equals(name.getPath()))
                crosshair = i;
        }
        count = layers.size();
        if (crosshair < 0)
            crosshair = Integer.MAX_VALUE; // nothing to split at: every layer drawn live
    }

    /** The HUD texture and its framebuffer, the size of the main colour texture (mcmetal may make that smaller). */
    private static boolean make(RenderTarget t) {
        int bound = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
        int boundFbo = GL11.glGetInteger(GL30.GL_DRAW_FRAMEBUFFER_BINDING);
        try {
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, t.getColorTextureId());
            int w = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_WIDTH);
            int h = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_HEIGHT);
            if (w <= 0 || h <= 0 || w != t.width || h != t.height)
                return false; // MetalFX: the world is drawn smaller than the HUD; leave the HUD alone
            if (tex == 0) {
                tex = GL11.glGenTextures();
                depth = GL11.glGenTextures();
                fbo = GL30.glGenFramebuffers();
            }
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
            GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA8, w, h, 0, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, (java.nio.ByteBuffer) null);
            GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MIN_FILTER, GL11.GL_NEAREST);
            GL11.glTexParameteri(GL11.GL_TEXTURE_2D, GL11.GL_TEXTURE_MAG_FILTER, GL11.GL_NEAREST);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, depth);
            GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL30.GL_DEPTH_COMPONENT32F, w, h, 0, GL11.GL_DEPTH_COMPONENT, GL11.GL_FLOAT, (java.nio.ByteBuffer) null);
            GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, fbo);
            GL30.glFramebufferTexture2D(GL30.GL_DRAW_FRAMEBUFFER, GL30.GL_COLOR_ATTACHMENT0, GL11.GL_TEXTURE_2D, tex, 0);
            GL30.glFramebufferTexture2D(GL30.GL_DRAW_FRAMEBUFFER, GL30.GL_DEPTH_ATTACHMENT, GL11.GL_TEXTURE_2D, depth, 0);
            return GL30.glCheckFramebufferStatus(GL30.GL_DRAW_FRAMEBUFFER) == GL30.GL_FRAMEBUFFER_COMPLETE;
        } finally {
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound); // Minecraft keeps track of what it bound
            GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, boundFbo);
        }
    }

    private static int savedFbo, mainFbo;

    /**
     * Draw into the HUD texture from here on, starting clear. The main target hands out the HUD's framebuffer
     * meanwhile, so a layer that draws elsewhere and then binds the main target back (Xaero's minimap does) comes
     * back to the HUD texture.
     */
    private static void begin() {
        RenderTarget t = Minecraft.getInstance().getMainRenderTarget();
        mainFbo = t.frameBufferId;
        t.frameBufferId = fbo;
        savedFbo = GL11.glGetInteger(GL30.GL_DRAW_FRAMEBUFFER_BINDING);
        float[] clear = new float[4];
        GL11.glGetFloatv(GL11.GL_COLOR_CLEAR_VALUE, clear);
        GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, fbo);
        GL11.glClearColor(0f, 0f, 0f, 0f);
        GL11.glClearDepth(1.0);
        GL11.glClear(GL11.GL_COLOR_BUFFER_BIT | GL11.GL_DEPTH_BUFFER_BIT);
        GL11.glClearColor(clear[0], clear[1], clear[2], clear[3]);
        GL11.glHint(HINT_HUD_FBO, fbo);
    }

    /** Back to the framebuffer the HUD was being drawn on. */
    private static void finish() {
        GL11.glHint(HINT_HUD_FBO, 0);
        Minecraft.getInstance().getMainRenderTarget().frameBufferId = mainFbo;
        GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER, savedFbo == fbo ? mainFbo : savedFbo);
    }

    /** The HUD texture over whatever is bound, as one triangle covering the target; GL state put back after. */
    private static void composite() {
        if (prog == 0 && !program())
            return;
        int oldProg = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
        int oldVao = GL11.glGetInteger(GL30.GL_VERTEX_ARRAY_BINDING);
        int oldUnit = GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE);
        GL13.glActiveTexture(GL13.GL_TEXTURE0);
        int oldTex = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
        boolean blend = GL11.glIsEnabled(GL11.GL_BLEND), depthTest = GL11.glIsEnabled(GL11.GL_DEPTH_TEST);
        boolean cull = GL11.glIsEnabled(GL11.GL_CULL_FACE), scissor = GL11.glIsEnabled(GL11.GL_SCISSOR_TEST);
        boolean depthMask = GL11.glGetBoolean(GL11.GL_DEPTH_WRITEMASK);
        int srcRgb = GL11.glGetInteger(GL14.GL_BLEND_SRC_RGB), dstRgb = GL11.glGetInteger(GL14.GL_BLEND_DST_RGB);
        int srcA = GL11.glGetInteger(GL14.GL_BLEND_SRC_ALPHA), dstA = GL11.glGetInteger(GL14.GL_BLEND_DST_ALPHA);
        int eqRgb = GL11.glGetInteger(GL20.GL_BLEND_EQUATION_RGB), eqA = GL11.glGetInteger(GL20.GL_BLEND_EQUATION_ALPHA);
        try {
            GL20.glUseProgram(prog);
            GL30.glBindVertexArray(vao);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
            GL11.glEnable(GL11.GL_BLEND);
            GL14.glBlendFuncSeparate(GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA, GL11.GL_ONE, GL11.GL_ONE_MINUS_SRC_ALPHA);
            GL20.glBlendEquationSeparate(GL14.GL_FUNC_ADD, GL14.GL_FUNC_ADD);
            GL11.glDisable(GL11.GL_DEPTH_TEST);
            GL11.glDepthMask(false);
            GL11.glDisable(GL11.GL_CULL_FACE);
            GL11.glDisable(GL11.GL_SCISSOR_TEST);
            GL11.glDrawArrays(GL11.GL_TRIANGLES, 0, 3);
        } finally {
            GL20.glBlendEquationSeparate(eqRgb, eqA);
            GL14.glBlendFuncSeparate(srcRgb, dstRgb, srcA, dstA);
            if (!blend) GL11.glDisable(GL11.GL_BLEND);
            if (depthTest) GL11.glEnable(GL11.GL_DEPTH_TEST);
            GL11.glDepthMask(depthMask);
            if (cull) GL11.glEnable(GL11.GL_CULL_FACE);
            if (scissor) GL11.glEnable(GL11.GL_SCISSOR_TEST);
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, oldTex);
            GL13.glActiveTexture(oldUnit);
            GL30.glBindVertexArray(oldVao);
            GL20.glUseProgram(oldProg);
        }
    }

    private static boolean program() {
        String vs = "#version 150 core\nout vec2 uv;\nvoid main() {\n"
                + "    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
                + "    uv = p;\n    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n}\n";
        String fs = "#version 150 core\nuniform sampler2D hud;\nin vec2 uv;\nout vec4 color;\n"
                + "void main() {\n    color = texture(hud, uv);\n}\n";
        int v = shader(GL20.GL_VERTEX_SHADER, vs), f = shader(GL20.GL_FRAGMENT_SHADER, fs);
        int p = GL20.glCreateProgram();
        GL20.glAttachShader(p, v);
        GL20.glAttachShader(p, f);
        GL20.glBindAttribLocation(p, 0, "unused");
        GL30.glBindFragDataLocation(p, 0, "color");
        GL20.glLinkProgram(p);
        GL20.glDeleteShader(v);
        GL20.glDeleteShader(f);
        if (GL20.glGetProgrami(p, GL20.GL_LINK_STATUS) == 0) {
            System.out.println("[mcmetal] HUD cache: its shader did not link, off: " + GL20.glGetProgramInfoLog(p));
            GL20.glDeleteProgram(p);
            state = -1;
            return false;
        }
        int oldProg = GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM);
        GL20.glUseProgram(p);
        GL20.glUniform1i(GL20.glGetUniformLocation(p, "hud"), 0);
        GL20.glUseProgram(oldProg);
        int oldVao = GL11.glGetInteger(GL30.GL_VERTEX_ARRAY_BINDING);
        vao = GL30.glGenVertexArrays(); // no attributes: the vertex shader makes the triangle from gl_VertexID
        GL30.glBindVertexArray(oldVao);
        prog = p;
        return true;
    }

    private static int shader(int type, String src) {
        int s = GL20.glCreateShader(type);
        GL20.glShaderSource(s, src);
        GL20.glCompileShader(s);
        return s;
    }
}
