/*
 * Amethyst-iOS: hands LWJGL 2 games a few of the launcher's GL hooks (Natives/sdl_gl_hooks.c) in place of
 * the renderer's own functions, for calls whose gl4es answer breaks them.
 */
package org.lwjgl.opengl;

import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

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
     * some functions resolve to the launcher's hooks (Natives/sdl_gl_hooks.c), both found by GT New Horizons 2.8
     * (Angelica 1):
     * - glGetIntegerv: gl4es doesn't answer GL_MAX_ATTRIB_STACK_DEPTH, so Angelica sized its glPushAttrib
     *   stacks to 0 and crashed in the first display list it compiled.
     * - glMultiDrawArrays: gl4es builds GL_QUADS index lists wrongly there, and crashed drawing chunks.
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
        long setGlFunction = launcher.getFunctionAddress("amethyst_gl4es_setGlFunction");
        if (setGlFunction == NULL) {
            return;
        }
        // Real functions the hooks call
        for (String function : new String[] {
                "glGetIntegerv", "glGetError", "glDrawArrays", "glMultiDrawArrays", "glDrawElements", "glBindBuffer"}) {
            passGlFunction(setGlFunction, function, real.getFunctionAddress(function));
        }
        // GL function name -> hook
        final Map<String, Long> hooks = new HashMap<String, Long>();
        long getIntegerv = launcher.getFunctionAddress("amethyst_gl4es_glGetIntegerv");
        if (getIntegerv != NULL && real.getFunctionAddress("glGetIntegerv") != NULL) {
            hooks.put("glGetIntegerv", getIntegerv);
        }
        long multiDrawArrays = launcher.getFunctionAddress("amethyst_gl4es_glMultiDrawArrays");
        if (multiDrawArrays != NULL && real.getFunctionAddress("glMultiDrawArrays") != NULL) {
            hooks.put("glMultiDrawArrays", multiDrawArrays);
            hooks.put("glMultiDrawArraysEXT", multiDrawArrays);
        }
        if (hooks.isEmpty()) {
            return;
        }

        FunctionProvider hooked = new FunctionProvider() {
            @Override
            public long getFunctionAddress(ByteBuffer functionName) {
                Long hook = hooks.get(memASCII(memAddress(functionName)));
                return hook != null ? hook : real.getFunctionAddress(functionName);
            }
        };
        Field provider = GL.class.getDeclaredField("functionProvider");
        provider.setAccessible(true);
        provider.set(null, hooked);
        System.out.println("[GLFunctionHooks] gl4es: hooked " + hooks.keySet());
    }

    private static void passGlFunction(long setGlFunction, String function, long address) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            invokePPV(memAddress(stack.ASCII(function)), address, setGlFunction);
        }
    }
}
