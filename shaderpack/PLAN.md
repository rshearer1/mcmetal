# Our own ray-traced shader pack (plan, 2026-10-21)

Working name: none yet, folder `shaderpack/`. Goal: an Iris pack that uses mcmetal's hardware ray tracing on
every Apple Silicon Mac. It must be shareable, which is why we write our own and don't patch Complementary or SEUS.

## Why our own pack (answers to Robert, 19:23Z)
- Complementary and SEUS PTGI both forbid sharing modified copies. We can patch either one for Robert's own Mac,
  but nobody else could get that patch. SEUS PTGI is the same as Complementary here.
- The trace call works in any pack, but only if that pack's source calls it. For their packs that means editing
  their code. mcmetal could rewrite their shaders on the player's machine at load time (the way Euphoria Patcher
  works), but that's fragile: every pack update breaks it. It's also a licence grey area unless the author agrees.
- Our own pack can be built around rays from the start, instead of bolting rays onto screen-space and voxel tricks.

## Rules for borrowing
We take **ideas and published techniques**, never code. We read their packs to see what looks good, then write it
ourselves from papers and public formulas. Examples: the ACES fitted curve (Stephen Hill / Narkowicz, public),
Hillaire/Bruneton sky, SVGF/A-SVGF denoising, Frostbite/LabPBR material formats.

| Idea | Seen in | Our version |
|---|---|---|
| ACES filmic grading (rich contrast, warm highlights) | SEUS | ACES fitted RRT+ODT, exposure + white balance sliders |
| Path-traced one-bounce GI, sky light through openings | SEUS PTGI | hardware bounce rays, 1 spp + temporal + spatial denoise |
| Coloured light from torches, lanterns, glowstone | Complementary ACT | emissive hits by block id add their colour, real rays, no voxel grid |
| Soft sun shadows with a penumbra | both | jittered sun-disc rays + temporal accumulation |
| Stylised but clean look, good defaults, clear menu | Complementary | presets (Low = M1/M2, High = M3+), short option names |
| Water: waves, refraction, reflections | both | ray-traced reflections (not screen space), so off-screen things reflect |
| Puddles and wet surfaces in rain | Complementary | rain wetness mask, sharper RT reflections when wet |
| LabPBR resource-pack support (normals, roughness, emission) | both | read normals/specular atlases when a PBR pack is loaded |
| Volumetric light / god rays | SEUS | march the view ray, one hardware shadow ray per step |
| Light-leak fix | Complementary | sky light from rays, so caves are dark for real |

## Feature order
Each step ships as a working pack that Robert can try.
1. **Base**: deferred G-buffer (albedo, normal, lightmap, material), our own sky (Rayleigh + Mie), sun/moon,
   ACES tonemap + exposure. RT sun shadows (hard), then soft shadows. Fallback shadow map when not on mcmetal.
2. **RT ambient occlusion**: short rays (1-2 m), 1 ray/pixel, temporal accumulation. Replaces vanilla's AO.
3. **Denoiser**: reprojection + history (temporal), then an edge-aware blur (spatial). Steps 4-5 need it.
4. **RT reflections**: water, glass, wet and shiny blocks. Needs a hit record from mcmetal (normal, colour, light).
5. **RT bounce light (GI)** + **coloured block light**. This is the SEUS PTGI / Complementary ACT look.
6. Water (waves, refraction, underwater fog), clouds, volumetric light, rain puddles.
7. Coloured glass shadows (needs a tinted trace in mcmetal), entities in the ray scene (mcmetal side).
8. Settings menu, presets per Mac generation, LabPBR, polish, licence, release.

## What mcmetal needs to add (asked in the Metal thread 19:27Z)
- `MCMETAL_RT` Iris macro, so the pack falls back to a shadow map on other systems.
- `mcm_trace_hit(o, d, tmax, out normal, out albedo, out lightmap, out blockId)`, for reflections and GI.
- `mcm_trace_tinted(o, d, tmax, out transmit)`, for coloured glass shadows.
- Entities and block entities in the ray scene (later).

## Budget (M3 Max, 2560x1440; mcmetal thread's numbers)
1 shadow ray/pixel = about 6 ms GPU. Target at 1440p on M3: shadows 1 rpp, AO 1 rpp, reflections 1 rpp on shiny
pixels only, GI 1 rpp at half resolution, all temporally accumulated. M1/M2 run the same rays on shader cores, so
their presets use half resolution and fewer rays.

## Testing
Bare MC 1.21.1 + NeoForge + Sodium + Iris + mcmetal. CI phase on GitHub macOS. Then Robert's Mac in ~/mcmetal-test,
booked through the Metal thread so two game runs don't collide.
