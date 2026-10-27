// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package dev.lambdaurora.lambdynlights.engine.source;
public interface EntityDynamicLightSource extends DynamicLightSource {
    double getDynamicLightX();
    double getDynamicLightY();
    double getDynamicLightZ();
    int getLuminance();
}
