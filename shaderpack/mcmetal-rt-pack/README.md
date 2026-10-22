# mcmetal RT pack (working name)

Our own Iris shader pack, built around hardware ray tracing through mcmetal on Apple Silicon Macs.
Plan and feature order: ../PLAN.md. Install: zip the folder that contains `shaders/` and put it in `shaderpacks/`.

Ideas come from other packs (SEUS, Complementary); the code is ours, written from public papers and formulas.
- Sky: single scattering (Nishita et al. 1993). Tonemap: ACES fitted curve (Stephen Hill, BakingLab, MIT).
- Normal packing: octahedral (Cigolle et al. 2014). Noise: interleaved gradient noise (Jimenez 2014).

Without mcmetal (RT_MODE Auto on other systems) it uses an ordinary shadow map.

Licence: MIT (see LICENSE): anyone may use, change and share the pack, in modpacks too, keeping the credit.
