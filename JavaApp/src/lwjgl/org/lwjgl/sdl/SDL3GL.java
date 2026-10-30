package org.lwjgl.sdl;

import java.io.File;
import java.nio.ByteBuffer;
import java.util.concurrent.ConcurrentHashMap;
import org.lwjgl.system.FunctionProvider;
import org.lwjgl.system.Library;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.SharedLibrary;
import org.lwjgl.system.JNI;

final class SDL3GL {
    private SDL3GL() {}
    private static native long nativeGLProcHook(long name, long real);
    private static FunctionProvider rendererProvider;
    private static final ConcurrentHashMap<String, Boolean> seen = new ConcurrentHashMap<>();

    static FunctionProvider provider() {
        // LWJGL may itself be using SDL_GL_GetProcAddress as its provider. Asking
        // GL.getFunctionProvider() here would then call back into us recursively.
        // Resolve symbols directly from the selected renderer instead.
        return loadRendererProvider();
    }

    private static synchronized FunctionProvider loadRendererProvider() {
        if (rendererProvider != null) return rendererProvider;
        String name = System.getProperty("org.lwjgl.opengl.libname");
        if (name == null || name.isEmpty()) return null;
        String bundle = System.getenv("BUNDLE_PATH");
        if (bundle != null && !new File(name).isAbsolute()) {
            File bundled = new File(new File(bundle, "Frameworks"), name);
            if (bundled.isFile()) name = bundled.getAbsolutePath();
        }
        try {
            final SharedLibrary library = Library.loadNative(SDL3GL.class, "org.lwjgl.opengl", name);
            long getProc = library.getFunctionAddress("OSMesaGetProcAddress");
            if (getProc == 0L) getProc = library.getFunctionAddress("eglGetProcAddress");
            if (getProc == 0L) getProc = library.getFunctionAddress("glXGetProcAddress");
            final long resolver = getProc;
            rendererProvider = new FunctionProvider() {
                public long getFunctionAddress(ByteBuffer function) {
                    long address = library.getFunctionAddress(function);
                    return address != 0L || resolver == 0L ? address
                        : JNI.invokePP(MemoryUtil.memAddress(function), resolver);
                }
            };
            once("provider.direct", "Loaded SDL GL/EGL entry points from " + library.getName());
            return rendererProvider;
        } catch (Throwable error) {
            once("provider.failed", "Could not load the selected SDL renderer: " + error);
            return null;
        }
    }

    static long lookup(long namePtr) {
        if (namePtr == 0L || SDL3Config.GL_SDL_PROC) return 0L;
        try {
            FunctionProvider provider = provider();
            if (provider == null) return 0L;
            long address = provider.getFunctionAddress(MemoryUtil.memUTF8(namePtr));
            return address == 0L ? 0L : nativeGLProcHook(namePtr, address);
        } catch (Throwable error) {
            once("lookup.failed", "SDL renderer function lookup failed: " + error);
            return 0L;
        }
    }

    static void once(String key, String line) {
        if (seen.putIfAbsent(key, Boolean.TRUE) == null) SDL3Bridge.warn(line);
    }
}
