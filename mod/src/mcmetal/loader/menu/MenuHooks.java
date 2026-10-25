package mcmetal.loader.menu;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL43;

/**
 * The world behind an open menu, kept as a picture (on unless MCMETAL_MENU_CACHE=0; see MenuWorldTransformer).
 *
 * Not used as a class: MenuWorldTransformer copies these static fields and methods into Minecraft's GameRenderer
 * (names prefixed "mcmetal$"). In GameRenderer.render(), `if (!skipWorld()) { renderLevel(); ... }` and then
 * afterWorld(), before the HUD and the screen are drawn.
 * While an inventory-style screen is open (the inventory, the creative menu, chests, furnaces, backpacks, any mod's
 * container, each with JEI's item list beside it) Minecraft still draws the whole world behind it every frame:
 * with a heavy shader pack and Distant Horizons that world is what sets the frame rate, so the menu ran at the
 * world's 40 fps. Now the world is drawn MCMETAL_MENU_WORLD_FPS times a second (default 10; 0 = once, when the
 * menu opens) and copied aside on the GPU; the frames in between put that copy back and only draw the menu on it.
 * The world behind a menu is dimmed and mostly covered, so its slower updates hardly show; the menu, the mouse and
 * JEI stay at full speed. Closing the menu draws the world every frame again straight away.
 * Compiled against signature stubs in mod/stubs; no static initializer, lambdas or nested classes (they would not
 * be copied), so every field starts at its default value.
 */
public final class MenuHooks {
    private static int state;          // 0 = settings not read yet, 1 = on, -1 = off
    private static long interval;      // ns between world frames while a menu is open; 0 = only the first
    private static int tex, texW, texH; // the copy of the world, and the main colour texture's size it was made for
    private static int forW, forH;     // the main target's size when the copy was made
    private static Screen forScreen;   // the screen it was made under (a new screen gets a fresh world first)
    private static long madeAt;
    private static boolean skipped;    // this frame's world was not drawn: put the copy back
    private static long frames, kept;  // menu frames, and those that reused the copy (for the log)

    private MenuHooks() {
    }

    /** Before the world is drawn: true to leave it out this frame and reuse the copy. */
    public static boolean skipWorld() {
        if (state == 0)
            init();
        skipped = false;
        if (state < 0)
            return false;
        Minecraft mc = Minecraft.getInstance();
        Screen s = mc.screen;
        if (!(s instanceof AbstractContainerScreen)) {
            forScreen = null;
            return false;
        }
        RenderTarget t = mc.getMainRenderTarget();
        if (++frames >= 1024 && Long.bitCount(frames) == 1) // now and then: how much it saves
            System.out.println("[mcmetal] menu world cache: " + kept + " of " + frames + " menu frames reused the world");
        if (s != forScreen || tex == 0 || forW != t.width || forH != t.height)
            return false;
        if (interval > 0 && System.nanoTime() - madeAt >= interval)
            return false;
        skipped = true;
        kept++;
        return true;
    }

    /** After the world (and its outline and post effects) would have been drawn, before the HUD and the screen. */
    public static void afterWorld() {
        if (state < 0)
            return;
        Minecraft mc = Minecraft.getInstance();
        RenderTarget t = mc.getMainRenderTarget();
        if (skipped) {
            copy(tex, t.getColorTextureId());
            return;
        }
        Screen s = mc.screen;
        if (!(s instanceof AbstractContainerScreen))
            return;
        if (tex == 0 || forW != t.width || forH != t.height)
            make(t);
        if (tex == 0)
            return;
        copy(t.getColorTextureId(), tex);
        forScreen = s;
        madeAt = System.nanoTime();
    }

    private static void init() {
        String on = System.getenv("MCMETAL_MENU_CACHE"), fps = System.getenv("MCMETAL_MENU_WORLD_FPS");
        if (on == null)
            on = System.getProperty("mcmetal.opt.MCMETAL_MENU_CACHE"); // mcmetal/options.txt
        if (fps == null)
            fps = System.getProperty("mcmetal.opt.MCMETAL_MENU_WORLD_FPS");
        int n = 10;
        try {
            if (fps != null)
                n = Math.max(0, Integer.parseInt(fps.trim()));
        } catch (NumberFormatException e) {
            // keep 10
        }
        interval = n == 0 ? 0 : 1_000_000_000L / n;
        state = "0".equals(on) ? -1 : 1;
        System.out.println("[mcmetal] menu world cache " + (state > 0 ? "on: the world behind a menu is drawn "
                + (n == 0 ? "once" : n + " times a second") : "off"));
    }

    /** A texture the size of the main colour texture (which mcmetal may have made smaller, for MetalFX). */
    private static void make(RenderTarget t) {
        int bound = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
        try {
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, t.getColorTextureId());
            int w = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_WIDTH);
            int h = GL11.glGetTexLevelParameteri(GL11.GL_TEXTURE_2D, 0, GL11.GL_TEXTURE_HEIGHT);
            if (tex == 0)
                tex = GL11.glGenTextures();
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, tex);
            GL11.glTexImage2D(GL11.GL_TEXTURE_2D, 0, GL11.GL_RGBA8, w, h, 0, GL11.GL_RGBA, GL11.GL_UNSIGNED_BYTE, (java.nio.ByteBuffer) null);
            texW = w;
            texH = h;
            forW = t.width;
            forH = t.height;
            forScreen = null;
            if (w <= 0 || h <= 0) {
                GL11.glDeleteTextures(tex);
                tex = 0;
            }
        } finally {
            GL11.glBindTexture(GL11.GL_TEXTURE_2D, bound); // Minecraft keeps track of what it bound
        }
    }

    /** One whole-texture copy on the GPU (a Metal blit), no draw state touched. */
    private static void copy(int from, int to) {
        GL43.glCopyImageSubData(from, GL11.GL_TEXTURE_2D, 0, 0, 0, 0, to, GL11.GL_TEXTURE_2D, 0, 0, 0, 0, texW, texH, 1);
    }
}
