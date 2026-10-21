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

int main(void)
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

    GLuint rb = program(NULL, NULL, readback_cs);
    check(really_linked(rb), "texture readback program links");

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
