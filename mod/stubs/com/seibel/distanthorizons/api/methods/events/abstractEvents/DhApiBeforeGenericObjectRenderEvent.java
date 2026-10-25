// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package com.seibel.distanthorizons.api.methods.events.abstractEvents;
public abstract class DhApiBeforeGenericObjectRenderEvent {
    public static class EventParam extends com.seibel.distanthorizons.api.methods.events.sharedParameterObjects.DhApiRenderParam {
        public String resourceLocationPath;
    }
}
