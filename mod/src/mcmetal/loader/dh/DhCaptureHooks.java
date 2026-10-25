package mcmetal.loader.dh;

import com.seibel.distanthorizons.api.DhApi;
import com.seibel.distanthorizons.api.enums.config.EDhApiDepthDirection;
import com.seibel.distanthorizons.api.enums.config.EDhApiDepthRange;
import com.seibel.distanthorizons.api.interfaces.render.IDhApiRenderProxy;
import com.seibel.distanthorizons.api.objects.DhApiResult;
import com.seibel.distanthorizons.api.objects.math.DhApiMat4f;
import com.seibel.distanthorizons.core.render.RenderParams;

/**
 * Distant Horizons' side of "DH behind packs without DH support" (see DhCompositeTransformer).
 *
 * Not used as a class: DhCompositeTransformer copies these static fields and methods into DH's LodRenderer (names
 * prefixed "mcmetal$") and calls dhCapture(params) just before DH copies its finished LOD picture to Minecraft's
 * screen. That moment has everything the Iris side needs to draw the LODs again after the shader pack's last pass:
 * DH's own colour and depth textures and the projection DH drew them with. The Iris side picks it up with
 * dhTake(), once per frame, through a method handle (Iris can't name DH's classes: DH may not be installed).
 * Compiled against signature stubs in mod/stubs; no static initializer, lambdas or nested classes.
 */
public final class DhCaptureHooks {
    private static float dhA, dhB, dhIx, dhIy, dhNear, dhFar; // projection: ndc z = (A*z + B) / -z; 1/P00, 1/P11
    private static int dhColor, dhDepth, dhFlags;            // flags: 1 = depth range 0..1, 2 = reverse Z
    private static boolean dhFresh, dhFailed;

    private DhCaptureHooks() {
    }

    /** DH's LOD picture for this frame is done (opaque, SSAO, water); about to be copied to Minecraft's screen. */
    public static void dhCapture(RenderParams p) {
        if (dhFailed)
            return;
        try {
            DhApiMat4f m = p.dhProjectionMatrix;
            if (m == null || m.m00 == 0f || m.m11 == 0f)
                return;
            // the perspective row is the one with -1 in w; DH's mRC naming could be either way round
            boolean rowMajor = Math.abs(m.m32 + 1f) < Math.abs(m.m23 + 1f);
            dhA = m.m22;
            dhB = rowMajor ? m.m23 : m.m32;
            dhIx = 1f / m.m00;
            dhIy = 1f / m.m11;
            dhNear = p.nearClipPlane;
            dhFar = p.farClipPlane;
            IDhApiRenderProxy rp = DhApi.Delayed.renderProxy;
            if (rp == null)
                return;
            DhApiResult<Integer> c = rp.getDhColorTextureGlId(), d = rp.getDhDepthTextureGlId();
            if (c == null || d == null || !c.success || !d.success)
                return;
            dhColor = c.payload;
            dhDepth = d.payload;
            dhFlags = (rp.getDepthRange() == EDhApiDepthRange.ZERO_TO_POS_ONE ? 1 : 0)
                    | (rp.getDepthDirection() == EDhApiDepthDirection.REVERSE_Z ? 2 : 0);
            dhFresh = true;
        } catch (Throwable t) {
            dhFailed = true; // a DH this was not written for: leave DH alone from now on
            System.out.println("[mcmetal] Distant Horizons behind shader packs: DH is not the expected one, off (" + t + ")");
        }
    }

    /** This frame's capture into out (A, B, 1/P00, 1/P11, near, far, colour, depth, flags); 0 if DH drew nothing. */
    public static int dhTake(float[] out) {
        if (!dhFresh)
            return 0;
        dhFresh = false;
        out[0] = dhA;
        out[1] = dhB;
        out[2] = dhIx;
        out[3] = dhIy;
        out[4] = dhNear;
        out[5] = dhFar;
        out[6] = dhColor;
        out[7] = dhDepth;
        out[8] = dhFlags;
        return 1;
    }
}
