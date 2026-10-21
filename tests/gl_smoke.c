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
        "void main() {\n"
        "  float bias = ((v_Material & 1u) != 0u) ? 0.0 : -16.0;\n"
        "  vec4 c = texture(u_BlockTex, v_TexCoord, bias) * v_Color;\n"
        "  if (v_FragDistance > u_FogStart) c.rgb = mix(c.rgb, u_FogColor.rgb, smoothstep(u_FogStart, u_FogEnd, v_FragDistance));\n"
        "  fragColor = c;\n"
        "}\n", NULL);
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
