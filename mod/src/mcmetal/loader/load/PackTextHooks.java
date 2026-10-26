package mcmetal.loader.load;

import net.minecraft.network.chat.Component;
import net.minecraft.network.chat.contents.TranslatableContents;

/**
 * A resource pack's description as Moonlight's asset cache fingerprints it, the same in every language (on unless
 * MCMETAL_LOAD_FIXES=0; see LoadSpeedTransformer).
 *
 * Not used as a class: LoadSpeedTransformer copies these static methods into Moonlight's GlobalCachedStrategy (names
 * prefixed "mcmetal$") and computeTokens() calls packText(description) where it called description.getString(). The
 * fingerprint says whether Every Compat's (and Supplementaries'...) generated assets on disk still match the packs and
 * mods; it holds each pack's description as text. Some descriptions are translation keys (NeoForge's "Resources for N
 * mod files") that only read as text once the mods' language files are loaded, so the first resource reload after a
 * launch saw an untranslated description, every later one a translated one: the cache looked stale on the first F3+T
 * or resource pack change of every session and Every Compat rebuilt it (27.8 s of a 77 s F3+T in the cloud,
 * 2026-10-26). Here a translated part counts by its key and arguments instead of its text, which never changes with
 * the language. Descriptions with no translated part give the same text as before. No static initializer, lambdas or
 * nested classes (they would not be copied).
 */
public final class PackTextHooks {
    private PackTextHooks() {
    }

    /** Stands in for description.getString() in the fingerprint. */
    private static String packText(Component c) {
        if (!translated(c))
            return c.getString();
        StringBuilder s = new StringBuilder();
        append(c, s);
        return s.toString();
    }

    private static boolean translated(Component c) {
        if (c.getContents() instanceof TranslatableContents)
            return true;
        for (Component sibling : c.getSiblings())
            if (translated(sibling))
                return true;
        return false;
    }

    private static void append(Component c, StringBuilder s) {
        if (c.getContents() instanceof TranslatableContents t) {
            s.append('{').append(t.getKey());
            for (Object arg : t.getArgs()) {
                s.append('|');
                if (arg instanceof Component a)
                    append(a, s);
                else
                    s.append(arg);
            }
            s.append('}');
        } else {
            s.append(c.getContents());
        }
        for (Component sibling : c.getSiblings())
            append(sibling, s);
    }
}
