package mcmetal.loader.sodium;

import net.minecraft.resources.ResourceLocation;

/**
 * Dynamic lights on the GPU: the light list in Sodium's terrain vertex shader (see DynLightTransformer). Not used as a
 * class: copied into Sodium's ShaderLoader (names prefixed "mcmetal$"), and loadShader() passes each shader's source
 * through it. Each vertex takes the brightest of LambDynamicLights' own falloff (luminance - distance * 15 / 7.75, out
 * to 7.75 blocks) over the list as its block light, if that beats the light baked into the chunk mesh. Until
 * DynLightHooks fills the list (u_McmDynLightCount stays 0) the shader draws exactly as before.
 */
public final class DynLightShaderHooks {
    private DynLightShaderHooks() {
    }

    /** Sodium's terrain vertex shader with the light list added; anything else as it is. */
    public static String shaderSource(String src, ResourceLocation id) {
        if (!"sodium".equals(id.getNamespace()) || !"blocks/block_layer_opaque.vsh".equals(id.getPath())
                || System.getProperty("mcmetal.dynlights.ldl") == null)
            return src;
        String light = "    v_Color = _vert_color * texture(u_LightTex, _vert_tex_light_coord);";
        String uniforms = "uniform sampler2D u_LightTex; // The light map texture sampler";
        if (!src.contains(light) || !src.contains(uniforms)) {
            System.out.println("[mcmetal] dynamic lights: Sodium's terrain shader is not the expected one, lights stay on the CPU");
            return src;
        }
        src = src.replace(uniforms, uniforms + "\n\n"
                + "// mcmetal: dynamic lights (LambDynamicLights) near the camera: xyz from the camera, w luminance\n"
                + "uniform vec4 u_McmDynLights[" + DynLightHooks.MAX + "];\n"
                + "uniform int u_McmDynLightCount;\n");
        return src.replace(light, ""
                + "    float mcmDyn = 0.0;\n"
                + "    for (int i = 0; i < u_McmDynLightCount; i++) {\n"
                + "        vec3 d = position - u_McmDynLights[i].xyz;\n"
                + "        float d2 = dot(d, d);\n"
                + "        if (d2 < 60.0625) mcmDyn = max(mcmDyn, u_McmDynLights[i].w - sqrt(d2) * (15.0 / 7.75));\n"
                + "    }\n"
                + "    if (mcmDyn > 0.0) _vert_tex_light_coord.x = max(_vert_tex_light_coord.x, clamp(mcmDyn * 16.0, 8.0, 248.0) / 256.0);\n"
                + light);
    }
}
