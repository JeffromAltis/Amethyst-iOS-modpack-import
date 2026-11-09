/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 */
package org.lwjgl.glfw;

import org.lwjgl.system.*;

import static org.lwjgl.system.Checks.*;
import static org.lwjgl.system.JNI.*;
import static org.lwjgl.system.MemoryUtil.*;

/** Utility class for GLFW callbacks. */
public final class Callbacks {

    private Callbacks() {}

    /**
     * Resets all callbacks for the specified GLFW window to {@code NULL} and {@link Callback#free frees} all previously set callbacks.
     *
     * <p>This method resets only callbacks registered with a GLFW window. Non-window callbacks (registered with
     * {@link GLFW#glfwSetErrorCallback SetErrorCallback}, {@link GLFW#glfwSetMonitorCallback SetMonitorCallback}, etc.) must be reset and freed
     * separately.</p>
     *
     * <p>This method is not official GLFW API. It exists in LWJGL to simplify window callback cleanup.</p>
     *
     * @param window the GLFW window
     */
    public static void glfwFreeCallbacks(@NativeType("GLFWwindow *") long window) {
        if (Checks.CHECKS) {
            check(window);
        }

        // A fixed list, not reflection over GLFW's methods: GLFW also has GLFW 3.4 text-input setters whose
        // callback types only exist in the LWJGL 3.4 bundle, so listing its methods would fail on LWJGL 3.3.
        // Those setters keep nothing, so there is nothing to clear for them.
        long current = GLFW.glfwGetCurrentContext();
        GLFW.glfwSetCharCallback(current, null);
        GLFW.glfwSetCharModsCallback(current, null);
        GLFW.glfwSetCursorEnterCallback(current, null);
        GLFW.glfwSetCursorPosCallback(current, null);
        GLFW.glfwSetDropCallback(current, null);
        GLFW.glfwSetErrorCallback(null);
        GLFW.glfwSetFramebufferSizeCallback(current, null);
        GLFW.glfwSetJoystickCallback(null);
        GLFW.glfwSetKeyCallback(current, null);
        GLFW.glfwSetMonitorCallback(null);
        GLFW.glfwSetMouseButtonCallback(current, null);
        GLFW.glfwSetScrollCallback(current, null);
        GLFW.glfwSetWindowCloseCallback(current, null);
        GLFW.glfwSetWindowContentScaleCallback(current, null);
        GLFW.glfwSetWindowFocusCallback(current, null);
        GLFW.glfwSetWindowIconifyCallback(current, null);
        GLFW.glfwSetWindowMaximizeCallback(current, null);
        GLFW.glfwSetWindowPosCallback(current, null);
        GLFW.glfwSetWindowRefreshCallback(current, null);
        GLFW.glfwSetWindowSizeCallback(current, null);
    }
}
