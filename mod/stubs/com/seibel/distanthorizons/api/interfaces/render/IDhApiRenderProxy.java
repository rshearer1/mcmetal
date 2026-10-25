// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package com.seibel.distanthorizons.api.interfaces.render;
import com.seibel.distanthorizons.api.objects.DhApiResult;
public interface IDhApiRenderProxy {
    DhApiResult<Integer> getDhColorTextureGlId();
    DhApiResult<Integer> getDhDepthTextureGlId();
    com.seibel.distanthorizons.api.enums.config.EDhApiDepthRange getDepthRange();
    com.seibel.distanthorizons.api.enums.config.EDhApiDepthDirection getDepthDirection();
}
