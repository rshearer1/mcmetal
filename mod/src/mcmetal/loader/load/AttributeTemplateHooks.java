package mcmetal.loader.load;

import it.unimi.dsi.fastutil.objects.ObjectOpenCustomHashSet;
import net.minecraft.world.entity.ai.attributes.AttributeInstance;

/**
 * ModernFix's attribute template sharing, skipped for templates that can never be shared (on unless
 * MCMETAL_LOAD_FIXES=0; see LoadSpeedTransformer). Idea from Nitro (MIT, github.com/TinsleyDevers/Nitro, fix 13); this
 * is our own code.
 *
 * Not used as a class: LoadSpeedTransformer copies this static method into ModernFix's
 * org.embeddedt.modernfix.entity.AttributeInstanceTemplates (name prefixed "mcmetal$"). ModernFix keeps one copy of
 * equal attribute templates in a hash set while every mob type's attributes are built at startup. Its equality compares
 * base values with ==, and Puffish Attributes gives its 41 "dynamic" attributes a base value of NaN, which is never ==
 * to anything: each such template hashes like all the others for its attribute and is never found, so it is added
 * after a walk past every earlier one (quadratic over all mob types) and the set keeps all of them. Such a template is
 * handed back as it is, which is what the set's addOrGet() returned for it anyway. No static initializer, lambdas or
 * nested classes (they would not be copied).
 */
public final class AttributeTemplateHooks {
    private AttributeTemplateHooks() {
    }

    /** Stands in for "INTERNER.addOrGet(template)". */
    public static Object addOrGet(ObjectOpenCustomHashSet<Object> set, Object template) {
        if (template instanceof AttributeInstance a && Double.isNaN(a.getBaseValue()))
            return template;
        return set.addOrGet(template);
    }
}
