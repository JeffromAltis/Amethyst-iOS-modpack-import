/*
 * Amethyst-iOS: overrides the org.lwjgl.opengl.GLContext copy shipped in lwjgl-lwjglx.jar (JavaApp/Makefile copies
 * JavaApp/src/lwjgl/** over the extracted jars).
 * Based on the upstream lwjglx source (AngelAuraMC/lwjgl3 wip/rebase_3.3.3), which matches the shipped jar (identical bytecode modulo constant-pool numbering).
 * Added for LWJGL 2 API parity:
 *  - useContext(Object), useContext(Object, boolean), loadOpenGLLibrary(), unloadOpenGLLibrary()
 */
package org.lwjgl.opengl;

import java.util.Map;
import java.util.WeakHashMap;

import org.lwjgl.LWJGLException;


public class GLContext {
    
    private static ThreadLocal<ContextCapabilities> contextCapabilities = new ThreadLocal<>();
    
    public static GLContext createFromCurrent() {
        return new GLContext();
    }
    public static void initCapabilities() {
        if(contextCapabilities.get() == null) {
            System.out.println("LWJGLX: GL caps init");
            contextCapabilities.set(new ContextCapabilities());
        }
    }
    public static ContextCapabilities getCapabilities() {
        return contextCapabilities.get();
    }

    /** Per-context capability cache (weak keys, as in LWJGL 2). */
    private static final Map<Object, ContextCapabilities> capabilityCache = new WeakHashMap<Object, ContextCapabilities>();
    private static int glRefCount = 0;
    private static boolean didAutoLoad = false;

    /**
     * Makes a GL context the current LWJGL context. See {@link #useContext(Object, boolean)}.
     */
    public static synchronized void useContext(Object context) throws LWJGLException {
        useContext(context, false);
    }

    /**
     * LWJGL 2 semantics on top of LWJGL 3: the context must already be current on the calling thread; this
     * (re)builds or reuses the cached {@link ContextCapabilities} for {@code context} and makes them current for
     * this thread (also in LWJGL 3's {@link GL}). {@code null} clears the current capabilities.
     * {@code forwardCompatible} is accepted for API compatibility; LWJGL 3 always loads every entry point the driver exposes.
     */
    public static synchronized void useContext(Object context, boolean forwardCompatible) throws LWJGLException {
        if (context == null) {
            contextCapabilities.remove();
            GL.setCapabilities(null);
            if (didAutoLoad) {
                didAutoLoad = false;
                unloadOpenGLLibrary();
            }
            return;
        }
        if (glRefCount == 0) {
            loadOpenGLLibrary();
            didAutoLoad = true;
        }
        try {
            ContextCapabilities caps = capabilityCache.get(context);
            if (caps == null) {
                // The constructor calls GL.createCapabilities(), which needs a current context and registers itself.
                caps = new ContextCapabilities();
                capabilityCache.put(context, caps);
            } else {
                GL.setCapabilities(caps.cap);
            }
            contextCapabilities.set(caps);
        } catch (RuntimeException e) {
            if (didAutoLoad) {
                didAutoLoad = false;
                unloadOpenGLLibrary();
            }
            throw new LWJGLException("Could not initialize capabilities for GL context: " + e);
        }
    }

    /**
     * Reference-counted like LWJGL 2. The LWJGL 3 GL class loads the OpenGL function provider itself
     * (statically or via GL.create), so this only ensures it is created.
     */
    public static synchronized void loadOpenGLLibrary() throws LWJGLException {
        if (glRefCount == 0 && GL.getFunctionProvider() == null) {
            try {
                GL.create();
            } catch (Throwable t) {
                throw new LWJGLException("Could not load the OpenGL library: " + t);
            }
        }
        glRefCount++;
    }

    /**
     * Decrements the reference count. The native library is intentionally never unloaded (the LWJGL 3 function
     * provider is shared with the running game; LWJGL 2 also skipped unloading on Linux).
     */
    public static synchronized void unloadOpenGLLibrary() {
        if (glRefCount > 0) glRefCount--;
    }
}
