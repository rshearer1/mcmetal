/* MCMETAL_DENOISE=1: MetalFX's denoiser (MTLFXTemporalDenoisedScaler, macOS 26, M3 and newer) in place of one of
   the pack's own passes.

   A pack opts in with a full-screen pass whose fragment shader says, in #define lines (for a pack loaded without
   Iris):
     #define MCMETAL_DENOISE_PASS
     #define MCMETAL_DENOISE_COLOR     colortex0       noisy lit colour (linear, HDR is fine)
     #define MCMETAL_DENOISE_DEPTH     depthtex0
     #define MCMETAL_DENOISE_NORMAL    colortex1       xy = signed octahedral normal, player (world) space
     #define MCMETAL_DENOISE_ALBEDO    colortex2       diffuse albedo in rgb
     #define MCMETAL_DENOISE_ROUGHNESS colortex10 b    linear roughness, in that channel (r, g, b or a)
     #define MCMETAL_DENOISE_SPECULAR  colortex10 a    optional: LabPBR F0 (>= 230/255 = metal), in that channel
     #define MCMETAL_DENOISE_MOTION    colortex15      optional: RG = previous - current position, in pixels;
                                                       without it mcmetal works out the camera's motion from depth
   Iris's preprocessor removes #define lines and comments before mcmetal sees the source, so a pack run through
   Iris says the same in unused constants, which survive: the role, two underscores, the sampler name, and
   optionally two underscores and the channel:
     const int MCMETAL_DENOISE_PASS = 1;
     const int MCMETAL_DENOISE_COLOR__colortex0 = 1;
     const int MCMETAL_DENOISE_ROUGHNESS__colortex10__b = 1;   (and so on for each role)
   Each named sampler must be declared, and read somewhere in the shader, or the compiler drops it. The pass writes
   its result to its first render target, and its own code is what runs when MetalFX can't (another Mac, the
   switch off): a plain copy of the colour, or the pack's own denoiser. With MetalFX the draw is replaced by
   MetalFX reading those textures and writing the first render target.
   Trace small, show big: when every input is smaller than the pass's render target (a pack tracing at half size
   into custom images from a compute pass, with its guides at that size too), MetalFX denoises and upscales to the
   target in one step. The depth input may then be a colour texture holding depth (R32F or R16F, 0..1 like
   depthtex0). The pack's own code for that pass must then upscale too, for when MetalFX can't run. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mgl_state.h"

enum { DN_COLOR, DN_DEPTH, DN_NORMAL, DN_ALBEDO, DN_ROUGHNESS, DN_SPECULAR, DN_MOTION, DN_ROLES };
static const char *const role_key[DN_ROLES] = {"COLOR", "DEPTH", "NORMAL", "ALBEDO", "ROUGHNESS", "SPECULAR", "MOTION"};

struct mgl_denoise_decl {
    char name[DN_ROLES][64]; /* sampler names, "" = not given */
    int channel[DN_ROLES];
};

int mgl_denoise_on(void)
{
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MCMETAL_DENOISE");
        on = e && atoi(e) == 1;
        if (on)
            mgl_log("denoiser: MetalFX will replace a pack's MCMETAL_DENOISE_PASS where this Mac can run it");
    }
    return on;
}

mgl_denoise_decl *mgl_denoise_parse(const char *fs)
{
    if (!fs || !mgl_denoise_on() || !strstr(fs, "MCMETAL_DENOISE_PASS"))
        return NULL;
    mgl_denoise_decl *d = calloc(1, sizeof *d);
    for (int r = 0; r < DN_ROLES; r++) {
        char key[64], ch = 0;
        snprintf(key, sizeof key, "#define MCMETAL_DENOISE_%s ", role_key[r]);
        const char *at = strstr(fs, key);
        d->channel[r] = r == DN_ROUGHNESS ? 0 : r == DN_SPECULAR ? 1 : 0; /* LabPBR: smoothness r, F0 g */
        char line[160];
        if (at) {
            if (sscanf(at + strlen(key), "%159[^\n]", line) != 1 || sscanf(line, "%63s %c", d->name[r], &ch) < 1)
                continue;
        } else {   /* the constant form: MCMETAL_DENOISE_ROLE__sampler[__c] */
            snprintf(key, sizeof key, "MCMETAL_DENOISE_%s__", role_key[r]);
            if (!(at = strstr(fs, key)) || sscanf(at + strlen(key), "%63[A-Za-z0-9]", d->name[r]) != 1)
                continue;
            const char *rest = at + strlen(key) + strlen(d->name[r]);
            if (rest[0] == '_' && rest[1] == '_')
                ch = rest[2];
        }
        if (ch == 'r' || ch == 'g' || ch == 'b' || ch == 'a')
            d->channel[r] = ch == 'r' ? 0 : ch == 'g' ? 1 : ch == 'b' ? 2 : 3;
    }
    if (!d->name[DN_COLOR][0] || !d->name[DN_DEPTH][0] || !d->name[DN_NORMAL][0] || !d->name[DN_ALBEDO][0] ||
        !d->name[DN_ROUGHNESS][0]) {
        mgl_log("denoiser: a MCMETAL_DENOISE_PASS lacks COLOR, DEPTH, NORMAL, ALBEDO or ROUGHNESS; left to the pack");
        free(d);
        return NULL;
    }
    mgl_log("denoiser: pack pass found (colour %s, depth %s, normal %s, albedo %s, roughness %s.%c%s%s%s%s)",
            d->name[DN_COLOR], d->name[DN_DEPTH], d->name[DN_NORMAL], d->name[DN_ALBEDO], d->name[DN_ROUGHNESS],
            "rgba"[d->channel[DN_ROUGHNESS]], d->name[DN_SPECULAR][0] ? ", specular " : "", d->name[DN_SPECULAR],
            d->name[DN_MOTION][0] ? ", motion " : "", d->name[DN_MOTION]);
    return d;
}

void mgl_denoise_free(mgl_denoise_decl *d) { free(d); }

/* The texture the draw has bound for the fragment stage's sampler `name` */
static mglb_texture *bound(const mgl_program *p, const mgl_draw *d, const char *name)
{
    if (!name[0])
        return NULL;
    for (int i = 0; i < p->x.num_textures; i++) {
        const mgl_texture_slot *s = &p->x.textures[i];
        int idx = s->msl_index[MGL_FRAGMENT];
        if (idx >= 0 && idx < MGL_MAX_TEXTURES && !strcmp(s->name, name))
            return d->textures[MGL_FRAGMENT][idx].tex;
    }
    return NULL;
}

int mgl_denoise_draw(const mgl_program *p, const mgl_draw *d)
{
    const mgl_denoise_decl *dd = p ? p->denoise : NULL;
    if (!dd || !d->target.tex[0] || d->target.is_default)
        return 0;
    mglb_denoise_in in = {0};
    mglb_texture **t[DN_ROLES] = {&in.color, &in.depth, &in.normal, &in.albedo, &in.roughness, &in.specular, &in.motion};
    for (int r = 0; r < DN_ROLES; r++) {
        *t[r] = bound(p, d, dd->name[r]);
        if (!*t[r] && dd->name[r][0]) {
            static int warned;
            if (!warned++)
                mgl_log("denoiser: the pass has no texture bound for %s (declared but unread?); pack pass runs", dd->name[r]);
            return 0;
        }
    }
    in.roughness_ch = dd->channel[DN_ROUGHNESS];
    in.specular_ch = dd->channel[DN_SPECULAR];
    in.out = d->target.tex[0];
    return mglb_denoise(&in);
}
