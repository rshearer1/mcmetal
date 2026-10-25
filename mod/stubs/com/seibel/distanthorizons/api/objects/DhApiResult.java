// Compile-only stand-in (signatures only) so mod/src can be compiled without the real mod; never packaged.
package com.seibel.distanthorizons.api.objects;
public class DhApiResult<T> {
    public final boolean success; // not "= false": javac would fold a constant into the caller
    public final T payload;
    private DhApiResult() { throw new AssertionError(); }
}
