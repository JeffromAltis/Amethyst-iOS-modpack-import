import java.lang.foreign.*;
import java.lang.invoke.*;

/** Diagnostic-only synchronous UIKit dispatch; no launcher or SDL hooks changed. */
public final class SDLProbeMainThread {
    private static final Linker LINKER = Linker.nativeLinker();
    private static final SymbolLookup SDL = SymbolLookup.libraryLookup(
            System.getProperty("amethyst.probe.resolvedSDL"), Arena.global());
    private static Runnable pending;
    private static Throwable failure;
    public static void run(Runnable action) throws Throwable {
        if (!System.getProperty("os.name").contains("Mac")) { action.run(); return; }
        SymbolLookup dispatch = SymbolLookup.libraryLookup("/usr/lib/system/libdispatch.dylib", Arena.global());
        // dispatch_get_main_queue is an inline accessor for this global queue.
        MemorySegment mainQueue = dispatch.findOrThrow("_dispatch_main_q");
        MethodHandle sync = LINKER.downcallHandle(dispatch.findOrThrow("dispatch_sync_f"),
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.ADDRESS));
        MethodHandle isMain = LINKER.downcallHandle(Linker.nativeLinker().defaultLookup().findOrThrow("pthread_main_np"),
                FunctionDescriptor.of(ValueLayout.JAVA_INT));
        if ((int)isMain.invokeExact() != 0) { action.run(); return; }
        pending = action;
        failure = null;
        try (Arena arena = Arena.ofShared()) {
            MemorySegment callback = LINKER.upcallStub(MethodHandles.lookup().findStatic(SDLProbeMainThread.class,
                    "invoke", MethodType.methodType(void.class, MemorySegment.class)),
                    FunctionDescriptor.ofVoid(ValueLayout.ADDRESS), arena);
            sync.invokeExact(mainQueue, MemorySegment.NULL, callback);
            if (failure != null) throw failure;
        } finally { pending = null; }
    }
    public static void ready() throws Throwable {
        LINKER.downcallHandle(SDL.findOrThrow("SDL_SetMainReady"), FunctionDescriptor.ofVoid()).invokeExact();
    }
    private static void invoke(MemorySegment context) {
        try { pending.run(); } catch (Throwable thrown) { failure = thrown; }
    }
}
