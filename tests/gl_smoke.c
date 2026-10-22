/* Headless smoke test for libmcmetal: no window, no Minecraft. Exercises the paths the game needs first and
   checks the pixels that come back, so a Mac (or a CI Mac) can tell in seconds whether the Metal backend works.
   Build: see build_mac.sh (build/gl_smoke). Run: build/gl_smoke   (exit code = number of failed checks)
   On the Linux null backend nothing executes on a GPU, so only the "links" checks are meaningful there. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "mgl_gl.h"

static int failed;
static void check(int ok, const char *what)
{
    printf("%s  %s\n", ok ? "PASS" : "FAIL", what);
    failed += !ok;
}

static GLuint shader(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    return s;
}

static GLuint program(const char *vs, const char *fs, const char *cs)
{
    GLuint p = glCreateProgram();
    if (vs) glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
    if (fs) glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
    if (cs) glAttachShader(p, shader(GL_COMPUTE_SHADER, cs));
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[4096] = "";
        glGetProgramInfoLog(p, sizeof log, NULL, log);
        printf("link failed:\n%s\n", log);
    }
    return p;
}

/* Linking is asynchronous (the Metal compile finishes in the background): a dispatch waits for it, and a
   failed Metal compile shows up as LINK_STATUS 0 afterwards. */
static int really_linked(GLuint p)
{
    GLint ok = 0;
    glFinish();
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    return ok;
}

static const char *readback_cs =
    "#version 430\n"
    "layout(local_size_x = 8, local_size_y = 8) in;\n"
    "uniform sampler2D tex;\n"
    "layout(std430, binding = 0) buffer Out { uint px[]; };\n"
    "void main() {\n"
    "  ivec2 c = ivec2(gl_GlobalInvocationID.xy);\n"
    "  vec4 v = texelFetch(tex, c, 0);\n"
    "  px[c.y * 64 + c.x] = packUnorm4x8(v);\n"
    "}\n";

/* reads a 64x64 RGBA8 texture through a compute shader (glReadPixels is not needed by the game, so it isn't there) */
static void read_texture(GLuint rb, GLuint tex, GLuint ssbo, unsigned *out)
{
    glUseProgram(rb);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glUniform1i(glGetUniformLocation(rb, "tex"), 0);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
    glDispatchCompute(8, 8, 1);
    glMemoryBarrier(GL_ALL_BARRIER_BITS);
    glFinish();
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    void *m = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, 64 * 64 * 4, GL_MAP_READ_BIT);
    if (m)
        memcpy(out, m, 64 * 64 * 4);
    else
        memset(out, 0, 64 * 64 * 4);
    glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
}

static unsigned rgba(int r, int g, int b, int a) { return (unsigned)(r | g << 8 | b << 16 | a << 24); }
static int near(unsigned px, unsigned want)
{
    for (int i = 0; i < 4; i++) {
        int a = (int)(px >> (8 * i) & 255), b = (int)(want >> (8 * i) & 255);
        if (abs(a - b) > 2)
            return 0;
    }
    return 1;
}

static char *read_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    rewind(f);
    char *b = malloc((size_t)n + 1);
    b[fread(b, 1, (size_t)n, f)] = 0;
    fclose(f);
    return b;
}

/* gl_smoke VSH FSH: run the terrain tests (6, 8, 9) with these shader files instead of the built-in look-alike,
   e.g. the GLSL a game run dumped (MGL_DUMP_DIR), with Sodium's attribute bindings */
static GLuint program_from_files(const char *vs_path, const char *fs_path)
{
    char *vs = read_file(vs_path), *fs = read_file(fs_path);
    if (!vs || !fs) {
        printf("cannot read %s / %s\n", vs_path, fs_path);
        exit(1);
    }
    GLuint p = glCreateProgram();
    glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
    glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
    static const char *names[4] = {"a_Position", "a_Color", "a_TexCoord", "a_LightAndData"};
    for (int i = 0; i < 4; i++)
        glBindAttribLocation(p, (GLuint)i, names[i]);
    glBindFragDataLocation(p, 0, "fragColor");
    glLinkProgram(p);
    printf("terrain tests use %s + %s\n", vs_path, fs_path);
    return p;
}

int main(int argc, char **argv)
{
    static unsigned px[64 * 64];
    const char *r = (const char *)glGetString(GL_RENDERER);
    printf("renderer: %s\n", r ? r : "?");
    if (r && strstr(r, "no Metal device")) { /* e.g. a CI virtual machine: compile checks happen offline instead */
        printf("SKIP  no Metal device here, nothing to draw with\n");
        return 0;
    }

    /* 1. compute writes a storage buffer, CPU maps it */
    GLuint cs = program(NULL, NULL,
                        "#version 430\nlayout(local_size_x = 64) in;\n"
                        "layout(std430, binding = 0) buffer B { uint v[]; };\n"
                        "void main() { v[gl_GlobalInvocationID.x] = gl_GlobalInvocationID.x * 3u + 1u; }\n");
    check(really_linked(cs), "compute program links (Metal compile)");
    GLuint ssbo;
    glGenBuffers(1, &ssbo);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    glBufferData(GL_SHADER_STORAGE_BUFFER, 64 * 64 * 4, NULL, GL_DYNAMIC_READ);
    glUseProgram(cs);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
    glDispatchCompute(1, 1, 1);
    glMemoryBarrier(GL_ALL_BARRIER_BITS);
    glFinish();
    unsigned *v = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, 256, GL_MAP_READ_BIT);
    check(v && v[0] == 1 && v[10] == 31 && v[63] == 190, "compute shader results read back");
    glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);

    /* 1b. shared vec3 [256][9] is 27 KB in GL but 36 KB as Metal float3 (limit 32 KB): Photon's sky light job */
    GLuint big = program(NULL, NULL,
                         "#version 430\nlayout(local_size_x = 256) in;\n"
                         "layout(std430, binding = 0) buffer B { float o[]; };\n"
                         "shared vec3 sm[256][9];\n"
                         "void main() { uint i = gl_LocalInvocationID.x;\n"
                         "  for (uint b = 0u; b < 9u; ++b) sm[i][b] = vec3(1.0, float(b), 2.0);\n"
                         "  barrier();\n"
                         "  for (uint s = 128u; s > 0u; s >>= 1) { if (i < s) for (uint b = 0u; b < 9u; ++b) sm[i][b] += sm[i + s][b]; barrier(); }\n"
                         "  if (i == 0u) { vec3 t = sm[0][8]; o[0] = t.x; o[1] = t.y; o[2] = t.z; } }\n");
    check(really_linked(big), "compute program with 36 KB of Metal float3 shared memory links (packed)");
    glUseProgram(big);
    glDispatchCompute(1, 1, 1);
    glMemoryBarrier(GL_ALL_BARRIER_BITS);
    glFinish();
    float *fo = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, 12, GL_MAP_READ_BIT);
    check(fo && fo[0] == 256.0f && fo[1] == 2048.0f && fo[2] == 512.0f, "packed shared vec3 reduction sums right");
    glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);

    GLuint rb = program(NULL, NULL, readback_cs);
    check(really_linked(rb), "texture readback program links");

    /* 1c. glClearTexImage (Iris clears packs' images every frame): a mixed pattern, all-equal bytes, zero, and the
       same pattern again (the GPU-side clear source is reused) */
    {
        GLuint ct;
        glGenTextures(1, &ct);
        glBindTexture(GL_TEXTURE_2D, ct);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 64, 64);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        static const unsigned char red[4] = {255, 0, 0, 255}, grey[4] = {7, 7, 7, 7}, none[4] = {0};
        const unsigned char *pat[4] = {red, grey, none, red};
        const unsigned want[4] = {rgba(255, 0, 0, 255), rgba(7, 7, 7, 7), rgba(0, 0, 0, 0), rgba(255, 0, 0, 255)};
        int ok = 1;
        for (int k = 0; k < 4; k++) {
            glClearTexImage(ct, 0, GL_RGBA, GL_UNSIGNED_BYTE, pat[k]);
            read_texture(rb, ct, ssbo, px);
            ok &= px[0] == want[k] && px[63 * 64 + 63] == want[k] && px[17 * 64 + 40] == want[k];
        }
        check(ok, "glClearTexImage: pattern, equal bytes, zero, pattern again");
        glDeleteTextures(1, &ct);
    }

    /* 2. framebuffer: clear, then a triangle with a uniform colour over the left half */
    GLuint tex, fbo;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 64, 64, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    check(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "framebuffer complete");
    glViewport(0, 0, 64, 64);
    glClearColor(0, 0, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    GLuint draw = program("#version 330 core\nlayout(location = 0) in vec2 pos;\n"
                          "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n",
                          "#version 330 core\nuniform vec4 color;\nout vec4 frag;\nvoid main() { frag = color; }\n", NULL);
    check(really_linked(draw), "vertex+fragment program links");
    /* left half of clip space: x -1..0 */
    float tri[] = {-1, -1, 0, -1, 0, 1, -1, -1, 0, 1, -1, 1};
    GLuint vao, vbo;
    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);
    glGenBuffers(1, &vbo);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof tri, tri, GL_STATIC_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, (void *)0);
    glUseProgram(draw);
    glUniform4f(glGetUniformLocation(draw, "color"), 1, 0, 0, 1);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    read_texture(rb, tex, ssbo, px);
    check(near(px[32 * 64 + 10], rgba(255, 0, 0, 255)), "draw: left half red");
    check(near(px[32 * 64 + 50], rgba(0, 0, 255, 255)), "clear: right half blue");
    check(near(px[2 * 64 + 10], rgba(255, 0, 0, 255)) && near(px[61 * 64 + 10], rgba(255, 0, 0, 255)),
          "draw covers bottom and top rows (orientation)");
    static unsigned rp[64 * 64];
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    glReadPixels(0, 0, 64, 64, GL_RGBA, GL_UNSIGNED_BYTE, rp);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    check(!memcmp(rp, px, sizeof rp), "glReadPixels matches the compute readback");

    /* 2b. Bliss's translucent pass: four targets (RGBA16F, RGBA8, RGBA16, RGBA16), blending SRC_ALPHA
       ONE_MINUS_SRC_ALPHA ONE_MINUS_DST_ALPHA ONE except on draw buffer 2 (glDisablei), two layers drawn. Buffer 2
       carries two 8-bit values packed in each 16-bit channel and must come back exactly */
    {
        static const GLenum fmt[4] = {GL_RGBA16F, GL_RGBA8, GL_RGBA16, GL_RGBA16};
        GLuint mt[4], mfbo;
        glGenTextures(4, mt);
        glGenFramebuffers(1, &mfbo);
        glBindFramebuffer(GL_FRAMEBUFFER, mfbo);
        for (int i = 0; i < 4; i++) {
            glBindTexture(GL_TEXTURE_2D, mt[i]);
            glTexStorage2D(GL_TEXTURE_2D, 1, fmt[i], 64, 64);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + (GLenum)i, GL_TEXTURE_2D, mt[i], 0);
        }
        static const GLenum bufs[4] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2, GL_COLOR_ATTACHMENT3};
        glDrawBuffers(4, bufs);
        check(glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, "four-target framebuffer complete");
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
        GLuint mrt = program("#version 330 core\nlayout(location = 0) in vec2 pos;\n"
                             "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n",
                             "#version 330 core\nuniform float layer;\n"
                             "layout(location = 0) out vec4 o0; layout(location = 1) out vec4 o1;\n"
                             "layout(location = 2) out vec4 o2; layout(location = 3) out vec4 o3;\n"
                             "float encodeVec2(vec2 a) { const vec2 c = vec2(1.0, 256.0) / 65535.0; vec2 t = floor(a * 255.0);"
                             " return t.x * c.x + t.y * c.y; }\n"
                             "void main() {\n"
                             "  o0 = vec4(0.5, 0.2, 0.1, 0.4);\n"
                             "  o1 = vec4(0.0, 0.0, 0.0, 0.7);\n"
                             "  o2 = vec4(encodeVec2(vec2(0.5, 0.5)), encodeVec2(vec2(0.8, 0.1 + layer * 0.1)),"
                             " encodeVec2(vec2(0.1, 0.45)), 1.0);\n"
                             "  o3 = vec4(0.0, 0.0, 0.0, 0.9);\n"
                             "}\n", NULL);
        check(really_linked(mrt), "four-target translucent program links");
        float full[] = {-1, -1, 3, -1, -1, 3};
        GLuint fvbo;
        glGenBuffers(1, &fvbo);
        glBindBuffer(GL_ARRAY_BUFFER, fvbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof full, full, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, (void *)0);
        glUseProgram(mrt);
        glEnable(GL_BLEND);
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE_MINUS_DST_ALPHA, GL_ONE);
        glDisablei(GL_BLEND, 2);
        for (int l = 0; l < 2; l++) {
            glUniform1f(glGetUniformLocation(mrt, "layer"), (float)l);
            glDrawArrays(GL_TRIANGLES, 0, 3);
        }
        glDisable(GL_BLEND);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, (void *)0);
        /* read back buffers 0 and 2 as raw floats, decoded the way Bliss's composite does */
        GLuint fr = program(NULL, NULL,
                            "#version 430\nlayout(local_size_x = 1) in;\n"
                            "uniform sampler2D t0; uniform sampler2D t2;\n"
                            "layout(std430, binding = 0) buffer Out { float o[]; };\n"
                            "vec2 decodeVec2(float a) { return fract(a * (65535.0 / vec2(256.0, 65536.0))) * (256.0 / 255.0); }\n"
                            "void main() { vec4 a = texelFetch(t0, ivec2(20, 20), 0); vec4 b = texelFetch(t2, ivec2(20, 20), 0);\n"
                            "  o[0] = a.a; o[1] = decodeVec2(b.g).y; o[2] = decodeVec2(b.b).y; o[3] = b.a; o[4] = decodeVec2(b.r).x; }\n");
        glUseProgram(fr);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, mt[0]);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, mt[2]);
        glActiveTexture(GL_TEXTURE0);
        glUniform1i(glGetUniformLocation(fr, "t0"), 0);
        glUniform1i(glGetUniformLocation(fr, "t2"), 1);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
        glDispatchCompute(1, 1, 1);
        glMemoryBarrier(GL_ALL_BARRIER_BITS);
        glFinish();
        glBindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
        float *mo = glMapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, 20, GL_MAP_READ_BIT);
        if (mo)
            printf("      four targets: buffer 0 alpha %.4f (want 0.64), buffer 2: %.5f %.5f %.4f %.4f (want 0.2 0.4471 1 0.498)\n",
                   mo[0], mo[1], mo[2], mo[3], mo[4]);
        check(mo && mo[0] > 0.63f && mo[0] < 0.65f, "four targets: blended alpha accumulates over two layers");
        check(mo && mo[1] > 0.19f && mo[1] < 0.21f && mo[2] > 0.44f && mo[2] < 0.455f && mo[3] == 1.0f && mo[4] > 0.49f && mo[4] < 0.51f,
              "four targets: unblended RGBA16 buffer keeps packed values exactly");
        glUnmapBuffer(GL_SHADER_STORAGE_BUFFER);
        glDeleteFramebuffers(1, &mfbo);
        glDeleteTextures(4, mt);
    }

    /* 3. texture upload + sampling: a 2x2 texture stretched over the target, nearest filtering */
    unsigned char texels[] = {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255};
    GLuint src;
    glGenTextures(1, &src);
    glBindTexture(GL_TEXTURE_2D, src);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 2, 2, 0, GL_RGBA, GL_UNSIGNED_BYTE, texels);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    GLuint samp = program("#version 330 core\nlayout(location = 0) in vec2 pos;\nout vec2 uv;\n"
                          "void main() { uv = pos * 0.5 + 0.5; gl_Position = vec4(pos, 0.0, 1.0); }\n",
                          "#version 330 core\nuniform sampler2D t;\nin vec2 uv;\nout vec4 frag;\n"
                          "void main() { frag = texture(t, uv); }\n", NULL);
    check(really_linked(samp), "sampling program links");
    float quad[] = {-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1};
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glUseProgram(samp);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, src);
    glUniform1i(glGetUniformLocation(samp, "t"), 0);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    read_texture(rb, tex, ssbo, px);
    /* GL: texel row 0 is the bottom, and our textures keep GL rows */
    check(near(px[8 * 64 + 8], rgba(255, 0, 0, 255)) && near(px[8 * 64 + 56], rgba(0, 255, 0, 255)) &&
          near(px[56 * 64 + 8], rgba(0, 0, 255, 255)) && near(px[56 * 64 + 56], rgba(255, 255, 255, 255)),
          "uploaded texture sampled in the right corners");

    /* 4. depth test: near red quad drawn after a far green one must win, then a farther blue one must lose */
    GLuint depth; /* a depth texture, as Minecraft uses (it never uses renderbuffers) */
    glGenTextures(1, &depth);
    glBindTexture(GL_TEXTURE_2D, depth);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT32F, 64, 64, 0, GL_DEPTH_COMPONENT, GL_FLOAT, NULL);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depth, 0);
    GLuint dprog = program("#version 330 core\nlayout(location = 0) in vec2 pos;\nuniform float z;\n"
                           "void main() { gl_Position = vec4(pos, z, 1.0); }\n",
                           "#version 330 core\nuniform vec4 color;\nout vec4 frag;\nvoid main() { frag = color; }\n", NULL);
    glClearDepth(1.0);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LESS);
    glUseProgram(dprog);
    GLint zl = glGetUniformLocation(dprog, "z"), cl = glGetUniformLocation(dprog, "color");
    glUniform1f(zl, 0.5f); glUniform4f(cl, 0, 1, 0, 1); glDrawArrays(GL_TRIANGLES, 0, 6);
    glUniform1f(zl, -0.5f); glUniform4f(cl, 1, 0, 0, 1); glDrawArrays(GL_TRIANGLES, 0, 6);
    glUniform1f(zl, 0.9f); glUniform4f(cl, 0, 0, 1, 1); glDrawArrays(GL_TRIANGLES, 0, 6);
    glDisable(GL_DEPTH_TEST);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    read_texture(rb, tex, ssbo, px);
    check(near(px[32 * 64 + 32], rgba(255, 0, 0, 255)), "depth test keeps the nearest surface");

    /* 6. a Sodium-style terrain quad: packed integer vertex data (uvec2 position in 20-bit thirds, ushort
       texcoords, ubyte light/material/draw id) in a 20-byte vertex, a lightmap read in the vertex stage, a flat
       uint varying, indexed UINT draw with a base vertex and index offset, back-face culling, depth LEQUAL.
       This is the shape of the first world draw that hangs the GPU in the game test. */
    GLuint terrain = program(
        "#version 330 core\n"
        "in uvec2 a_Position;\nin vec4 a_Color;\nin uvec2 a_TexCoord;\nin uvec4 a_LightAndData;\n"
        "uniform mat4 u_ProjectionMatrix;\nuniform mat4 u_ModelViewMatrix;\nuniform vec3 u_RegionOffset;\n"
        "uniform vec2 u_TexCoordShrink;\nuniform int u_FogShape;\nuniform sampler2D u_LightTex;\n"
        "out vec4 v_Color;\nout vec2 v_TexCoord;\nout float v_FragDistance;\nflat out uint v_Material;\n"
        "uvec3 deint(uvec2 d) { uvec3 hi = (uvec3(d.x) >> uvec3(0u, 10u, 20u)) & 0x3FFu;\n"
        "  uvec3 lo = (uvec3(d.y) >> uvec3(0u, 10u, 20u)) & 0x3FFu; return (hi << 10u) | lo; }\n"
        "float dist(int shape, vec3 p) { switch (shape) { case 0: return length(p);\n"
        "  case 1: return max(length(p.xz), abs(p.y)); default: return length(p); } }\n"
        "void main() {\n"
        "  vec3 pos = vec3(deint(a_Position)) * (32.0 / 1048576.0) - 8.0;\n"
        "  uvec3 rel = uvec3(a_LightAndData[3]) >> uvec3(5u, 0u, 2u) & uvec3(7u, 3u, 7u);\n"
        "  pos += u_RegionOffset + vec3(rel) * 16.0;\n"
        "  v_FragDistance = dist(u_FogShape, pos);\n"
        "  gl_Position = u_ProjectionMatrix * u_ModelViewMatrix * vec4(pos, 1.0);\n"
        "  v_Color = a_Color * texture(u_LightTex, vec2(a_LightAndData.xy) / vec2(256.0));\n"
        "  vec2 bias = mix(vec2(-1.0), vec2(1.0), bvec2(a_TexCoord >> 15u));\n"
        "  v_TexCoord = bias * u_TexCoordShrink + vec2(a_TexCoord & 32767u) / 32768.0;\n"
        "  v_Material = a_LightAndData[2];\n"
        "}\n",
        "#version 330 core\n"
        "in vec4 v_Color;\nin vec2 v_TexCoord;\nin float v_FragDistance;\nflat in uint v_Material;\n"
        "uniform sampler2D u_BlockTex;\nuniform vec4 u_FogColor;\nuniform float u_FogStart;\nuniform float u_FogEnd;\n"
        "out vec4 fragColor;\n"
        "const float[4] ALPHA_CUTOFF = float[4](0.0, 0.1, 0.1, 1.0);\n"
        "void main() {\n"
        "  float bias = ((v_Material & 1u) != 0u) ? 0.0 : -16.0;\n"
        "  vec4 c = texture(u_BlockTex, v_TexCoord, bias) * v_Color;\n"
        "  if (c.a < ALPHA_CUTOFF[(v_Material >> 1u) & 3u]) discard;\n"
        "  if (v_FragDistance > u_FogStart) c.rgb = mix(c.rgb, u_FogColor.rgb, smoothstep(u_FogStart, u_FogEnd, v_FragDistance));\n"
        "  fragColor = c;\n"
        "}\n", NULL);
    if (argc == 3)
        terrain = program_from_files(argv[1], argv[2]);
    check(really_linked(terrain), "Sodium-style terrain program links");
    /* 4 junk vertices, then the quad; positions decode to clip-space corners at z 0.5 (identity matrices) */
    struct { unsigned pos[2]; unsigned char color[4]; unsigned short uv[2]; unsigned char light[4]; } tv[8];
    memset(tv, 0xEE, sizeof tv);
    static const float corner[4][2] = {{-1, -1}, {1, -1}, {1, 1}, {-1, 1}};
    for (int i = 0; i < 4; i++) {
        unsigned c[3] = {(unsigned)((corner[i][0] + 8) * 32768), (unsigned)((corner[i][1] + 8) * 32768), (unsigned)(8.5 * 32768)};
        tv[4 + i].pos[0] = (c[0] >> 10) | (c[1] >> 10) << 10 | (c[2] >> 10) << 20;
        tv[4 + i].pos[1] = (c[0] & 1023) | (c[1] & 1023) << 10 | (c[2] & 1023) << 20;
        tv[4 + i].color[0] = 255; tv[4 + i].color[1] = 128; tv[4 + i].color[2] = 0; tv[4 + i].color[3] = 255;
        tv[4 + i].uv[0] = tv[4 + i].uv[1] = 0x4000; /* 0.5, bias bit clear */
        tv[4 + i].light[0] = tv[4 + i].light[1] = 8; tv[4 + i].light[2] = 1; tv[4 + i].light[3] = 0;
    }
    unsigned tidx[10] = {7, 7, 7, 7, 0, 1, 2, 0, 2, 3}; /* drawn from byte offset 16 with base vertex 4 */
    GLuint tvao, tbuf[2], white[2];
    glGenVertexArrays(1, &tvao);
    glBindVertexArray(tvao);
    glGenBuffers(2, tbuf);
    glBindBuffer(GL_ARRAY_BUFFER, tbuf[0]);
    glBufferData(GL_ARRAY_BUFFER, sizeof tv, tv, GL_STATIC_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, tbuf[1]);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof tidx, tidx, GL_STATIC_DRAW);
    GLint la[4];
    const char *an[4] = {"a_Position", "a_Color", "a_TexCoord", "a_LightAndData"};
    for (int i = 0; i < 4; i++) {
        la[i] = glGetAttribLocation(terrain, an[i]);
        if (la[i] >= 0) glEnableVertexAttribArray((GLuint)la[i]);
    }
    check(la[0] >= 0 && la[1] >= 0 && la[2] >= 0 && la[3] >= 0, "terrain attribute locations found");
    if (la[0] >= 0) glVertexAttribIPointer((GLuint)la[0], 2, GL_UNSIGNED_INT, 20, (void *)0);
    if (la[1] >= 0) glVertexAttribPointer((GLuint)la[1], 4, GL_UNSIGNED_BYTE, GL_TRUE, 20, (void *)8);
    if (la[2] >= 0) glVertexAttribIPointer((GLuint)la[2], 2, GL_UNSIGNED_SHORT, 20, (void *)12);
    if (la[3] >= 0) glVertexAttribIPointer((GLuint)la[3], 4, GL_UNSIGNED_BYTE, 20, (void *)16);
    unsigned char wt[16 * 16 * 4];
    memset(wt, 255, sizeof wt);
    glGenTextures(2, white);
    for (int i = 0; i < 2; i++) {
        glActiveTexture(GL_TEXTURE0 + (GLenum)i);
        glBindTexture(GL_TEXTURE_2D, white[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, wt);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    }
    static const float ident[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    glUseProgram(terrain);
    glUniformMatrix4fv(glGetUniformLocation(terrain, "u_ProjectionMatrix"), 1, GL_FALSE, ident);
    glUniformMatrix4fv(glGetUniformLocation(terrain, "u_ModelViewMatrix"), 1, GL_FALSE, ident);
    glUniform3f(glGetUniformLocation(terrain, "u_RegionOffset"), 0, 0, 0);
    glUniform2f(glGetUniformLocation(terrain, "u_TexCoordShrink"), 0, 0);
    glUniform1i(glGetUniformLocation(terrain, "u_FogShape"), 1);
    glUniform1i(glGetUniformLocation(terrain, "u_BlockTex"), 0);
    glUniform1i(glGetUniformLocation(terrain, "u_LightTex"), 1);
    glUniform4f(glGetUniformLocation(terrain, "u_FogColor"), 0, 0, 1, 1);
    glUniform1f(glGetUniformLocation(terrain, "u_FogStart"), 100);
    glUniform1f(glGetUniformLocation(terrain, "u_FogEnd"), 200);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glClearColor(0, 0, 1, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    glEnable(GL_CULL_FACE);
    glDrawElementsBaseVertex(GL_TRIANGLES, 6, GL_UNSIGNED_INT, (void *)16, 4);
    glFinish();
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glActiveTexture(GL_TEXTURE0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindVertexArray(vao);
    read_texture(rb, tex, ssbo, px);
    printf("      terrain centre pixel %08x (want ff0080ff)\n", px[32 * 64 + 32]);
    check(near(px[32 * 64 + 32], rgba(255, 128, 0, 255)) && near(px[2 * 64 + 2], rgba(255, 128, 0, 255)),
          "Sodium-style terrain quad draws with the right colour");

    /* 7. a cloud-style draw: float3 position + normalized ubyte4 colour (16-byte vertex), USHORT indices,
       depth test + write, discard in the fragment stage (Sodium's cloud renderer, the first draw that hung) */
    GLuint cloud = program("#version 150\nin vec3 Position;\nin vec4 Color;\nuniform mat4 ModelViewMat;\nuniform mat4 ProjMat;\n"
                           "out float vertexDistance;\nout vec4 vertexColor;\n"
                           "void main() { gl_Position = ProjMat * ModelViewMat * vec4(Position, 1.0);\n"
                           "  vertexDistance = length((ModelViewMat * vec4(Position.x, 0.0, Position.z, 1.0)).xyz);\n"
                           "  vertexColor = Color; }\n",
                           "#version 150\nuniform vec4 ColorModulator;\nin vec4 vertexColor;\nin float vertexDistance;\n"
                           "out vec4 fragColor;\n"
                           "void main() { vec4 c = vertexColor * ColorModulator; if (c.a < 0.1) discard;\n"
                           "  fragColor = vec4(c.rgb, clamp(c.a * (vertexDistance < 100.0 ? 1.0 : 0.0), 0.0, 1.0)); }\n", NULL);
    check(really_linked(cloud), "cloud-style program links");
    struct { float p[3]; unsigned char c[4]; } cv[4];
    for (int i = 0; i < 4; i++) {
        cv[i].p[0] = corner[i][0]; cv[i].p[1] = corner[i][1]; cv[i].p[2] = 0.25f;
        cv[i].c[0] = 0; cv[i].c[1] = 255; cv[i].c[2] = 0; cv[i].c[3] = 255;
    }
    unsigned short cidx[6] = {0, 1, 2, 0, 2, 3};
    GLuint cvao, cbuf[2];
    glGenVertexArrays(1, &cvao);
    glBindVertexArray(cvao);
    glGenBuffers(2, cbuf);
    glBindBuffer(GL_ARRAY_BUFFER, cbuf[0]);
    glBufferData(GL_ARRAY_BUFFER, sizeof cv, cv, GL_STATIC_DRAW);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, cbuf[1]);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof cidx, cidx, GL_STATIC_DRAW);
    GLint pl = glGetAttribLocation(cloud, "Position"), col = glGetAttribLocation(cloud, "Color");
    check(pl >= 0 && col >= 0, "cloud attribute locations found");
    if (pl >= 0) { glEnableVertexAttribArray((GLuint)pl); glVertexAttribPointer((GLuint)pl, 3, GL_FLOAT, GL_FALSE, 16, (void *)0); }
    if (col >= 0) { glEnableVertexAttribArray((GLuint)col); glVertexAttribPointer((GLuint)col, 4, GL_UNSIGNED_BYTE, GL_TRUE, 16, (void *)12); }
    glUseProgram(cloud);
    glUniformMatrix4fv(glGetUniformLocation(cloud, "ModelViewMat"), 1, GL_FALSE, ident);
    glUniformMatrix4fv(glGetUniformLocation(cloud, "ProjMat"), 1, GL_FALSE, ident);
    glUniform4f(glGetUniformLocation(cloud, "ColorModulator"), 1, 1, 1, 1);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (void *)0);
    glFinish();
    glDisable(GL_DEPTH_TEST);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glBindVertexArray(vao);
    read_texture(rb, tex, ssbo, px);
    printf("      cloud centre pixel %08x (want ff00ff00)\n", px[32 * 64 + 32]);
    check(near(px[32 * 64 + 32], rgba(0, 255, 0, 255)), "cloud-style quad draws with the right colour");

    /* 8. the game's own terrain draw, replayed: real camera matrices and region offset from a CI game run, a
       4 MB vertex buffer with the quad near its end (base vertex 192032), glMultiDrawElementsBaseVertex, the
       same program as test 6. Variants switch one ingredient off at a time to find the one that breaks. */
    for (int variant = 0; variant < 5; variant++) {
        static const char *vname[] = {"all game ingredients", "single draw instead of multi-draw",
                                      "identity camera instead of the game's", "small buffer and base vertex",
                                      "region offset 0, draw id 0"};
        int multi = variant != 1, real_cam = variant != 2, big_buf = variant != 3, real_region = variant != 4;
        static const float proj_game[16] = {0.91201955f, 0, -0.0f, -0.0f, 0, 1.4301808f, -0.0f, -0.0f, 0, 0, -1.0002604f, -1,
                                            0, -0.0f, -0.10001303f, -0.0f};
        static const float mv_game[16] = {0.86602533f, -0.24999994f, 0.43301257f, 0, 0, 0.86602527f, 0.49999997f, 0,
                                          -0.49999985f, -0.43301269f, 0.74999994f, 0, 0, 0, 0, 1};
        const float *proj = real_cam ? proj_game : ident, *mv = real_cam ? mv_game : ident;
        const float reg[3] = {real_region ? -71.5f : 0, real_region ? -5.6182251f : 0, real_region ? -9.5f : 0};
        const unsigned draw_id = real_region ? 128 : 0; /* section (4, 0, 0) of the region */
        const float rel[3] = {real_region ? 64.0f : 0, 0, 0};
        /* game camera: 5 blocks in front in view space; identity: straight into clip space */
        float view[4][3] = {{-1, -1, -5}, {1, -1, -5}, {1, 1, -5}, {-1, 1, -5}};
        if (!real_cam)
            for (int i = 0; i < 4; i++) {
                view[i][0] *= 0.5f; view[i][1] *= 0.5f; view[i][2] = 0.5f;
            }
        const size_t big = big_buf ? 3870720 : 400, base = big_buf ? 192032 : 4;
        unsigned char *vb = calloc(1, big);
        for (int i = 0; i < 4; i++) {
            float w[3];
            for (int r = 0; r < 3; r++) /* world = transpose(mv) * view, mv being a pure rotation */
                w[r] = mv[r * 4 + 0] * view[i][0] + mv[r * 4 + 1] * view[i][1] + mv[r * 4 + 2] * view[i][2];
            unsigned c[3];
            for (int k = 0; k < 3; k++)
                c[k] = (unsigned)((w[k] - reg[k] - rel[k] + 8) * 32768);
            unsigned char *v = vb + (base + (size_t)i) * 20;
            unsigned px0 = (c[0] >> 10) | (c[1] >> 10) << 10 | (c[2] >> 10) << 20;
            unsigned px1 = (c[0] & 1023) | (c[1] & 1023) << 10 | (c[2] & 1023) << 20;
            memcpy(v, &px0, 4);
            memcpy(v + 4, &px1, 4);
            v[8] = 255; v[9] = 128; v[10] = 0; v[11] = 255;
            unsigned short uv[2] = {0x4000, 0x4000};
            memcpy(v + 12, uv, 4);
            v[16] = 8; v[17] = 8; v[18] = 1; v[19] = (unsigned char)draw_id;
        }
        unsigned qidx[12] = {0, 1, 2, 2, 3, 0, 0, 3, 2, 2, 1, 0}; /* both windings */
        GLuint rvao, rbuf[2];
        glGenVertexArrays(1, &rvao);
        glBindVertexArray(rvao);
        glGenBuffers(2, rbuf);
        glBindBuffer(GL_ARRAY_BUFFER, rbuf[0]);
        glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)big, vb, GL_DYNAMIC_DRAW);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, rbuf[1]);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof qidx, qidx, GL_STATIC_DRAW);
        free(vb);
        for (int i = 0; i < 4; i++)
            if (la[i] >= 0) glEnableVertexAttribArray((GLuint)la[i]);
        if (la[0] >= 0) glVertexAttribIPointer((GLuint)la[0], 2, GL_UNSIGNED_INT, 20, (void *)0);
        if (la[1] >= 0) glVertexAttribPointer((GLuint)la[1], 4, GL_UNSIGNED_BYTE, GL_TRUE, 20, (void *)8);
        if (la[2] >= 0) glVertexAttribIPointer((GLuint)la[2], 2, GL_UNSIGNED_SHORT, 20, (void *)12);
        if (la[3] >= 0) glVertexAttribIPointer((GLuint)la[3], 4, GL_UNSIGNED_BYTE, 20, (void *)16);
        glUseProgram(terrain);
        glUniformMatrix4fv(glGetUniformLocation(terrain, "u_ProjectionMatrix"), 1, GL_FALSE, proj);
        glUniformMatrix4fv(glGetUniformLocation(terrain, "u_ModelViewMatrix"), 1, GL_FALSE, mv);
        glUniform3f(glGetUniformLocation(terrain, "u_RegionOffset"), reg[0], reg[1], reg[2]);
        glUniform2f(glGetUniformLocation(terrain, "u_TexCoordShrink"), -3.0517578e-05f, -9.1552734e-05f);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, white[0]);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, white[1]);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glClearColor(0, 0, 1, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LEQUAL);
        if (multi) {
            GLsizei counts[3] = {12, 6, 6};
            const void *offs[3] = {(void *)0, (void *)0, (void *)24};
            GLint bases[3] = {(GLint)base, (GLint)base, (GLint)base};
            glMultiDrawElementsBaseVertex(GL_TRIANGLES, counts, GL_UNSIGNED_INT, offs, 3, bases);
        } else
            glDrawElementsBaseVertex(GL_TRIANGLES, 12, GL_UNSIGNED_INT, (void *)0, (GLint)base);
        glFinish();
        glDisable(GL_DEPTH_TEST);
        glActiveTexture(GL_TEXTURE0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindVertexArray(vao);
        read_texture(rb, tex, ssbo, px);
        char what[160];
        snprintf(what, sizeof what, "game terrain draw replayed: %s (centre pixel %08x)", vname[variant], px[32 * 64 + 32]);
        check(near(px[32 * 64 + 32], rgba(255, 128, 0, 255)), what);
    }

    /* 9. Sodium's cutout pass: material bits pick an alpha cutoff from a constant array, so a fully transparent
       texel must be discarded with material 5 (cutoff 0.1) and kept with material 1 (cutoff 0). */
    for (int variant = 0; variant < 4; variant++) {
        /* 0: material 5 (mips, cutoff 0.1)  1: material 1 (cutoff 0)  2: material 2 (no mips: bias -16, cutoff 0.1)
           3: material 2 on a mipmapped texture with a mipmap filter, like the block atlas */
        static const int mat[4] = {5, 1, 2, 2};
        unsigned char clear_px[16 * 16 * 4];
        for (int i = 0; i < 16 * 16; i++) {
            clear_px[4 * i] = clear_px[4 * i + 1] = clear_px[4 * i + 2] = 255;
            clear_px[4 * i + 3] = 0;
        }
        GLuint ctex;
        glGenTextures(1, &ctex);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, ctex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, clear_px);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, variant == 3 ? GL_NEAREST_MIPMAP_LINEAR : GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        if (variant == 3) {
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 4);
            glGenerateMipmap(GL_TEXTURE_2D);
        }
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, white[1]);
        for (int i = 0; i < 4; i++)
            tv[4 + i].light[2] = (unsigned char)mat[variant];
        glBindVertexArray(tvao);
        glBindBuffer(GL_ARRAY_BUFFER, tbuf[0]);
        glBufferData(GL_ARRAY_BUFFER, sizeof tv, tv, GL_STATIC_DRAW);
        glUseProgram(terrain);
        glUniformMatrix4fv(glGetUniformLocation(terrain, "u_ProjectionMatrix"), 1, GL_FALSE, ident);
        glUniformMatrix4fv(glGetUniformLocation(terrain, "u_ModelViewMatrix"), 1, GL_FALSE, ident);
        glUniform3f(glGetUniformLocation(terrain, "u_RegionOffset"), 0, 0, 0);
        glUniform2f(glGetUniformLocation(terrain, "u_TexCoordShrink"), 0, 0);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glClearColor(0, 0, 1, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        glDrawElementsBaseVertex(GL_TRIANGLES, 6, GL_UNSIGNED_INT, (void *)16, 4);
        glFinish();
        glActiveTexture(GL_TEXTURE0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glBindVertexArray(vao);
        read_texture(rb, tex, ssbo, px);
        char what[160];
        snprintf(what, sizeof what, "cutout material %d%s: transparent texel %s (centre pixel %08x)", mat[variant],
                 variant == 3 ? ", mipmapped texture" : "", variant == 1 ? "kept" : "discarded", px[32 * 64 + 32]);
        check(variant != 1 ? near(px[32 * 64 + 32], rgba(0, 0, 255, 255)) : near(px[32 * 64 + 32], rgba(255, 128, 0, 0)), what);
    }

    /* 10. ACT-style voxel volume: vertex shaders imageStore block ids into an r16ui 3D image, a later draw
       reads them back with texelFetch through a usampler3D bound to the same texture (Complementary's
       voxel_img / voxel_sampler: coloured light and connected glass both read it this way) */
    {
        GLuint vox;
        glGenTextures(1, &vox);
        glBindTexture(GL_TEXTURE_3D, vox);
        glTexImage3D(GL_TEXTURE_3D, 0, GL_R16UI, 8, 8, 8, 0, GL_RED_INTEGER, GL_UNSIGNED_SHORT, NULL);
        GLuint write = program("#version 430\nlayout(r16ui) uniform writeonly uimage3D voxel_img;\n"
                               "void main() {\n"
                               "  imageStore(voxel_img, ivec3(gl_VertexID, 1, 2), uvec4(uint(gl_VertexID) + 100u, 0u, 0u, 0u));\n"
                               "  gl_Position = vec4(2.0, 2.0, 2.0, 1.0);\n" /* off screen: nothing rasterised */
                               "}\n",
                               "#version 430\nout vec4 frag;\nvoid main() { frag = vec4(1.0); }\n", NULL);
        GLuint read = program("#version 330 core\nlayout(location = 0) in vec2 pos;\n"
                              "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n",
                              "#version 430\nuniform usampler3D voxel_sampler;\nout vec4 frag;\n"
                              "void main() {\n"
                              "  uint a = texelFetch(voxel_sampler, ivec3(1, 1, 2), 0).x & 32767u;\n"
                              "  uint b = texelFetch(voxel_sampler, ivec3(5, 1, 2), 0).x;\n"
                              "  uint c = texelFetch(voxel_sampler, ivec3(1, 2, 2), 0).x;\n" /* never written: 0 */
                              "  frag = vec4(float(a) / 255.0, float(b) / 255.0, c == 0u ? 1.0 : 0.0, 1.0);\n"
                              "}\n", NULL);
        check(really_linked(write) && really_linked(read), "voxel volume programs link (uimage3D in a vertex shader)");
        for (int variant = 0; variant < 2; variant++) {
            unsigned short zero[8 * 8 * 8] = {0};
            glBindTexture(GL_TEXTURE_3D, vox);
            glTexSubImage3D(GL_TEXTURE_3D, 0, 0, 0, 0, 8, 8, 8, GL_RED_INTEGER, GL_UNSIGNED_SHORT, zero);
            GLint filter = variant ? GL_LINEAR : GL_NEAREST; /* linear on an integer texture: GL ignores it for texelFetch */
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, filter);
            glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, filter);
            glBindFramebuffer(GL_FRAMEBUFFER, fbo);
            glDisable(GL_DEPTH_TEST);
            glBindImageTexture(0, vox, 0, GL_TRUE, 0, GL_WRITE_ONLY, GL_R16UI);
            glUseProgram(write);
            glUniform1i(glGetUniformLocation(write, "voxel_img"), 0);
            glBindVertexArray(vao);
            glDrawArrays(GL_POINTS, 0, 8);
            glMemoryBarrier(GL_ALL_BARRIER_BITS);
            glClearColor(0, 0, 0, 1);
            glClear(GL_COLOR_BUFFER_BIT);
            glUseProgram(read);
            glActiveTexture(GL_TEXTURE3);
            glBindTexture(GL_TEXTURE_3D, vox);
            glUniform1i(glGetUniformLocation(read, "voxel_sampler"), 3);
            glBindBuffer(GL_ARRAY_BUFFER, vbo);
            glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
            glDrawArrays(GL_TRIANGLES, 0, 6);
            glActiveTexture(GL_TEXTURE0);
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            read_texture(rb, tex, ssbo, px);
            char what[160];
            snprintf(what, sizeof what, "voxel volume written by vertex shader, read by texelFetch (%s filter): pixel %08x",
                     variant ? "linear" : "nearest", px[32 * 64 + 32]);
            check(near(px[32 * 64 + 32], rgba(101, 105, 255, 255)), what);
        }
    }

    /* 11. integer vertex data into a float input without normalising (Iris's mc_midTexCoord on Sodium terrain):
       GL hands the shader 100.0 and 200.0, not 100/65535 */
    {
        GLuint scaled = program("#version 330 core\nlayout(location = 0) in vec2 pos;\nlayout(location = 1) in vec2 raw;\n"
                                "out vec2 v;\nvoid main() { v = raw; gl_Position = vec4(pos, 0.0, 1.0); }\n",
                                "#version 330 core\nin vec2 v;\nout vec4 frag;\n"
                                "void main() { frag = vec4(v.x / 255.0, v.y / 255.0, 0.0, 1.0); }\n", NULL);
        check(really_linked(scaled), "scaled-attribute program links");
        unsigned short raw[12];
        for (int i = 0; i < 6; i++) {
            raw[2 * i] = 100;
            raw[2 * i + 1] = 200;
        }
        GLuint rbuf;
        glGenBuffers(1, &rbuf);
        glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
        glBindBuffer(GL_ARRAY_BUFFER, rbuf);
        glBufferData(GL_ARRAY_BUFFER, sizeof raw, raw, GL_STATIC_DRAW);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_UNSIGNED_SHORT, GL_FALSE, 4, (void *)0);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        glDisable(GL_DEPTH_TEST);
        glDisable(GL_BLEND);
        glClearColor(0, 0, 1, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        glUseProgram(scaled);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDisableVertexAttribArray(1);
        read_texture(rb, tex, ssbo, px);
        char what[160];
        snprintf(what, sizeof what, "unnormalised unsigned shorts reach a float input as 100, 200 (pixel %08x)", px[32 * 64 + 32]);
        check(near(px[32 * 64 + 32], rgba(100, 200, 0, 255)), what);
    }

    /* 12. layout(binding) in a #version 330 shader with the SSBO extension (Complementary's world-space
       reflections): GL drivers accept it, glslang only with GL_ARB_shading_language_420pack */
    check(really_linked(program("#version 330 core\nlayout(location = 0) in vec2 pos;\n"
                                "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n",
                                "#version 330 core\n#extension GL_ARB_shader_storage_buffer_object : require\n"
                                "layout(std430, binding = 3) buffer B { uint v[]; };\nout vec4 frag;\n"
                                "void main() { frag = vec4(float(v[0])); }\n", NULL)),
          "layout(binding) in a #version 330 shader compiles");

    /* 5. hardware ray tracing: a shader using mcm_trace must compile on Metal (no scene bound: no hits) */
    GLuint rt = program(NULL, NULL,
                        "#version 430\nlayout(local_size_x = 1) in;\n"
                        "float mcm_trace(vec3 origin, vec3 dir, float tmax);\n"
                        "layout(std430, binding = 0) buffer B { float r[]; };\n"
                        "void main() { r[0] = mcm_trace(vec3(0.0), vec3(0.0, 1.0, 0.0), 100.0); }\n");
    check(really_linked(rt), "ray-query (mcm_trace) program compiles on Metal");

    printf("%d check(s) failed\n", failed);
    return failed;
}
