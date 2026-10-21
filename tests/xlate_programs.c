/* Run every captured program (DIR/pNNN/vertex.glsl, fragment.glsl, compute.glsl) through mgl_xlate_program.
   Usage: xlate_programs DIR [OUTDIR]   (OUTDIR gets <prog>.<stage>.metal and <prog>.reflect.txt) */
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mgl_xlate.h"

static char *slurp(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    char *s = malloc((size_t)n + 1);
    s[fread(s, 1, (size_t)n, f)] = 0;
    fclose(f);
    return s;
}

int main(int argc, char **argv)
{
    static const char *const names[MGL_NUM_STAGES] = {"vertex", "fragment", "compute"};
    DIR *d = opendir(argv[1]);
    struct dirent *e;
    int ok = 0, fail = 0, over16 = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] != 'p')
            continue;
        const char *src[MGL_NUM_STAGES];
        char path[4096];
        for (int s = 0; s < MGL_NUM_STAGES; s++) {
            snprintf(path, sizeof path, "%s/%s/%s.glsl", argv[1], e->d_name, names[s]);
            src[s] = slurp(path);
        }
        mgl_xlate_result r;
        mgl_xlate_program(src, &r);
        if (r.ok) {
            ok++;
            if (r.log && strstr(r.log, "past Metal's 16"))
                over16++;
        } else {
            fail++;
            printf("FAIL %s\n%s\n", e->d_name, r.log ? r.log : "(no log)");
        }
        if (argc > 2 && r.ok) {
            for (int s = 0; s < MGL_NUM_STAGES; s++) {
                if (!r.msl[s])
                    continue;
                snprintf(path, sizeof path, "%s/%s.%s.metal", argv[2], e->d_name, names[s]);
                FILE *f = fopen(path, "w");
                fputs(r.msl[s], f);
                fclose(f);
            }
            snprintf(path, sizeof path, "%s/%s.reflect.txt", argv[2], e->d_name);
            FILE *f = fopen(path, "w");
            fprintf(f, "default block bytes: vs %d fs %d cs %d\n", r.default_block_size[0], r.default_block_size[1], r.default_block_size[2]);
            for (int i = 0; i < r.num_attribs; i++)
                fprintf(f, "attrib %s loc %d vec%d%s\n", r.attribs[i].name, r.attribs[i].location, r.attribs[i].vecsize, r.attribs[i].is_int ? " int" : "");
            for (int i = 0; i < r.num_uniforms; i++) {
                mgl_uniform *u = &r.uniforms[i];
                fprintf(f, "uniform %s kind %d vec%d cols%d arr%d off vs %d fs %d cs %d\n", u->name, u->kind, u->vecsize, u->columns, u->array_size, u->offset[0], u->offset[1], u->offset[2]);
            }
            for (int i = 0; i < r.num_textures; i++) {
                mgl_texture_slot *t = &r.textures[i];
                fprintf(f, "texture %s dim %d%s%s idx vs %d fs %d cs %d\n", t->name, t->dim, t->is_image ? " image" : "", t->is_shadow ? " shadow" : "", t->msl_index[0], t->msl_index[1], t->msl_index[2]);
            }
            for (int i = 0; i < r.num_ubos; i++)
                fprintf(f, "ubo %s binding %d size %d\n", r.ubos[i].name, r.ubos[i].binding, r.ubos[i].size);
            for (int i = 0; i < r.num_outs; i++)
                fprintf(f, "out %s loc %d\n", r.outs[i].name, r.outs[i].location);
            if (r.log)
                fprintf(f, "log: %s", r.log);
            fclose(f);
        }
        mgl_xlate_free(&r);
        for (int s = 0; s < MGL_NUM_STAGES; s++)
            free((void *)src[s]);
    }
    printf("programs ok %d, failed %d, ok but >16 samplers %d\n", ok, fail, over16);
    return fail != 0;
}
