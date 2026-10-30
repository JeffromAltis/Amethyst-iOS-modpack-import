package org.lwjgl.sdl;

import java.io.File;
import java.lang.reflect.Method;
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
    private static volatile Method getProvider;
    private static volatile boolean reflectionUnavailable;
    private static FunctionProvider rendererProvider;
    private static final ConcurrentHashMap<String, Boolean> seen = new ConcurrentHashMap<>();

    static FunctionProvider provider() {
        if (!reflectionUnavailable) {
            try {
                Method method = getProvider;
                if (method == null) {
                    method = Class.forName("org.lwjgl.opengl.GL", true, SDL3GL.class.getClassLoader()).getMethod("getFunctionProvider");
                    getProvider = method;
                }
                Object provider = method.invoke(null);
                if (provider instanceof FunctionProvider) return (FunctionProvider)provider;
            } catch (Throwable error) {
                reflectionUnavailable = true;
                once("provider.reflection", "Using the selected renderer directly: " + error);
            }
        }
        // lwjgl3ify deliberately initializes LWJGL GL only after creating its SDL context.
        // Resolve the selected renderer independently to avoid a circular initialization dependency.
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
