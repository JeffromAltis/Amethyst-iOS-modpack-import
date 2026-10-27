/*
 * Amethyst-iOS: hands LWJGL 2 games a few of the launcher's GL hooks (Natives/sdl_gl_hooks.c) in place of
 * the renderer's own functions, for calls whose gl4es answer breaks them.
 */
package org.lwjgl.opengl;

import java.lang.reflect.Field;
import java.nio.ByteBuffer;

import org.lwjgl.glfw.GLFW;
import org.lwjgl.system.FunctionProvider;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.SharedLibrary;

import static org.lwjgl.system.JNI.invokePPV;
import static org.lwjgl.system.MemoryUtil.NULL;
import static org.lwjgl.system.MemoryUtil.memASCII;
import static org.lwjgl.system.MemoryUtil.memAddress;

final class GLFunctionHooks {
    private GLFunctionHooks() {}

    private static boolean installed;

    /**
     * {@link GL#createCapabilities()}, after (once) wrapping LWJGL's GL function provider so that, on gl4es,
     * glGetIntegerv resolves to amethyst_gl4es_glGetIntegerv: gl4es doesn't answer GL_MAX_ATTRIB_STACK_DEPTH,
     * so Angelica 1 (GT New Horizons 2.8) sized its glPushAttrib stacks to 0 and crashed in the first
     * display list it compiled.
     */
    static synchronized GLCapabilities createCapabilities() {
        if (!installed) {
            installed = true;
            try {
                install();
            } catch (Throwable t) {
                System.err.println("[GLFunctionHooks] Could not install the GL hooks: " + t);
            }
        }
        return GL.createCapabilities();
    }

    private static void install() throws Exception {
        String renderer = System.getenv("RENDERER");
        if (renderer == null || !renderer.contains("gl4es")) {
            return;
        }
        final FunctionProvider real = GL.getFunctionProvider();
        if (real == null) {
            return;
        }
        SharedLibrary launcher = GLFW.getLibrary();
        final long hook = launcher.getFunctionAddress("amethyst_gl4es_glGetIntegerv");
        long setGlFunction = launcher.getFunctionAddress("amethyst_sdl_setGlFunction");
        long realGetIntegerv = real.getFunctionAddress("glGetIntegerv");
        if (hook == NULL || setGlFunction == NULL || realGetIntegerv == NULL) {
            return;
        }
        passGlFunction(setGlFunction, "glGetIntegerv", realGetIntegerv);
        passGlFunction(setGlFunction, "glGetError", real.getFunctionAddress("glGetError"));

        FunctionProvider hooked = new FunctionProvider() {
            @Override
            public long getFunctionAddress(ByteBuffer functionName) {
                if ("glGetIntegerv".equals(memASCII(memAddress(functionName)))) {
                    return hook;
                }
                return real.getFunctionAddress(functionName);
            }
        };
        Field provider = GL.class.getDeclaredField("functionProvider");
        provider.setAccessible(true);
        provider.set(null, hooked);
        System.out.println("[GLFunctionHooks] gl4es: glGetIntegerv hooked");
    }

    private static void passGlFunction(long setGlFunction, String function, long address) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            invokePPV(memAddress(stack.ASCII(function)), address, setGlFunction);
        }
    }
}
