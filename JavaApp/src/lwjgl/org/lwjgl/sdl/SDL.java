package org.lwjgl.sdl;

import org.lwjgl.system.Configuration;
import org.lwjgl.system.Library;
import org.lwjgl.system.Platform;
import org.lwjgl.system.SharedLibrary;
import org.lwjgl.system.MemoryUtil;
import java.nio.ByteBuffer;

public final class SDL {
    private static final SharedLibrary SDL;

    public static SharedLibrary getLibrary() {
        return SDL;
    }

    private SDL() {
        throw new UnsupportedOperationException();
    }

    static {
        System.load(System.getenv("BUNDLE_PATH") + "/AngelAuraAmethyst");
        System.out.println("[SDL3 TRACE] SDL class init BEGIN");
        System.out.println("[SDL3 TRACE] nativePrepare BEGIN");
        SDL3Bridge.nativePrepare();
        System.out.println("[SDL3 TRACE] nativePrepare END");
        System.out.println("[SDL3 TRACE] Library.loadNative BEGIN");
        final SharedLibrary library = Library.loadNative(
            SDL.class,
            "org.lwjgl.sdl",
            Configuration.SDL_LIBRARY_NAME.get(Platform.mapLibraryNameBundled("SDL3")),
            true
        );
        SDL = new SharedLibrary() {
            public String getName() { return library.getName(); }
            public String getPath() { return library.getPath(); }
            public long address() { return library.address(); }
            public void free() { library.free(); }
            public long getFunctionAddress(ByteBuffer name) {
                long address = library.getFunctionAddress(name);
                return SDL3Bridge.nativeGPUProcHook(MemoryUtil.memAddress(name), address);
            }
        };
        System.out.println("[SDL3 TRACE] Library.loadNative END");
        System.out.println("[SDL3 TRACE] nativeLoaded BEGIN");
        SDL3Bridge.nativeLoaded();
        System.out.println("[SDL3 TRACE] nativeLoaded END");
        System.out.println("[SDL3 TRACE] SDL class init END");
    }
}
