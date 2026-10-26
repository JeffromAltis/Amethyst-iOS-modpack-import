package org.lwjgl.glfw;

import java.lang.reflect.Constructor;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.Map;
import java.util.Optional;
import java.util.WeakHashMap;

/**
 * Runtime hooks that make Controlify work fully with Amethyst's gamepad passthrough.
 *
 * Controlify gets rumble and controller identification from its SDL3 backend and a
 * USB/HID scan, neither of which can run on iOS. With passthrough it uses its GLFW
 * backend instead, and the patchjna agent's ControlifyCompatTransformer rewires that
 * backend to call these hooks:
 *
 *  - {@link #fetchType}: replaces GLFWControllerManager's ControllerHIDService.fetchType(jid)
 *    call. Identifies the controller from the vendor/product IDs iOS reports (carried
 *    in the passthrough joystick GUID), so Controlify shows the right button prompts.
 *  - {@link #addComponents}: runs at the end of GLFWGamepadDriver.addComponents and
 *    attaches a RumbleComponent when the controller has haptics.
 *  - {@link #update}: runs at the start of GLFWGamepadDriver.update and forwards queued
 *    rumble to {@link GLFW#amethystSetJoystickRumble}.
 *
 * Controlify classes live in the mod class loader, so everything here is reflective
 * and failures only disable the feature, never input.
 */
public final class ControlifyCompat {
    private static final String TAG = "[ControlifyCompat] ";

    private static final Map<Object, Object> rumbleComponents = Collections.synchronizedMap(new WeakHashMap<Object, Object>());
    private static volatile Api api;

    private ControlifyCompat() {}

    /** Reflection handles into Controlify, resolved once from its class loader. */
    private static final class Api {
        final ClassLoader loader;
        final Class<?> hidIdClass, controllerTypeClass, rumbleComponentClass;
        final Constructor<?> hidId, hidInfo, rumbleComponent;
        final Constructor<?> idOnlyDevice; // null on Controlify versions without HIDDevice.IDOnly
        final Object defaultType;
        final Method controlifyInstance, consumeRumble;

        Api(ClassLoader loader) throws ReflectiveOperationException {
            this.loader = loader;
            hidIdClass = load("dev.isxander.controlify.hid.HIDID");
            controllerTypeClass = load("dev.isxander.controlify.controller.id.ControllerType");
            rumbleComponentClass = load("dev.isxander.controlify.controller.rumble.RumbleComponent");
            hidId = hidIdClass.getConstructor(int.class, int.class);
            hidInfo = load("dev.isxander.controlify.hid.ControllerHIDService$ControllerHIDInfo")
                .getConstructor(controllerTypeClass, Optional.class);
            rumbleComponent = rumbleComponentClass.getConstructor();
            defaultType = controllerTypeClass.getField("DEFAULT").get(null);
            controlifyInstance = load("dev.isxander.controlify.Controlify").getMethod("instance");
            consumeRumble = rumbleComponentClass.getMethod("consumeRumble");

            Constructor<?> idOnly = null;
            try {
                idOnly = load("dev.isxander.controlify.hid.HIDDevice$IDOnly").getConstructor(int.class, int.class, String.class);
            } catch (ReflectiveOperationException ignored) {
            }
            idOnlyDevice = idOnly;
        }

        private Class<?> load(String name) throws ClassNotFoundException {
            return Class.forName(name, true, loader);
        }
    }

    private static Api api(Object controlifyObject) throws ReflectiveOperationException {
        ClassLoader loader = controlifyObject.getClass().getClassLoader();
        Api current = api;
        if (current == null || current.loader != loader) {
            current = api = new Api(loader);
        }
        return current;
    }

    private static void log(String message) {
        System.out.println(TAG + message);
    }

    // ---- Controller identification ----

    /** Replacement for {@code service.fetchType(jid)}; returns a ControllerHIDInfo. */
    public static Object fetchType(Object service, int jid) throws Throwable {
        try {
            Object info = typeFromJoystickGUID(service, jid);
            if (info != null) return info;
        } catch (Throwable t) {
            log("controller type lookup failed: " + t);
        }
        try {
            return service.getClass().getMethod("fetchType", int.class).invoke(service, jid);
        } catch (InvocationTargetException e) {
            throw e.getCause();
        }
    }

    private static Object typeFromJoystickGUID(Object service, int jid) throws ReflectiveOperationException {
        int[] ids = vendorProductFromGUID(GLFW.glfwGetJoystickGUID(jid));
        if (ids == null) {
            log("joystick " + jid + " has no known vendor/product, using Controlify's lookup");
            return null;
        }
        int vendor = ids[0], product = ids[1];

        Api api = api(service);
        Object controlify = api.controlifyInstance.invoke(null);
        Object typeManager = controlify.getClass().getMethod("controllerTypeManager").invoke(controlify);
        Object hidId = api.hidId.newInstance(vendor, product);
        Object type = typeManager.getClass().getMethod("getControllerType", api.hidIdClass).invoke(typeManager, hidId);
        if (type == null) type = api.defaultType;

        // Hand over the IDs as an ID-only HID device too: if Controlify's identification
        // table wasn't loaded yet, its resource reload re-identifies controllers that
        // have one (ControllerTypeManager.reloadTypeForController).
        Optional<Object> device = api.idOnlyDevice != null
            ? Optional.<Object>of(api.idOnlyDevice.newInstance(vendor, product, "ios-gamecontroller-" + jid))
            : Optional.empty();
        if (!device.isPresent() && type.equals(api.defaultType)) {
            return null; // nothing gained over Controlify's own lookup
        }

        log(String.format("joystick %d is %04x:%04x -> %s", jid, vendor, product, type));
        return api.hidInfo.newInstance(type, device);
    }

    /**
     * Vendor and product from an SDL2-style joystick GUID (32 hex digits: bus, crc,
     * vendor, 0, product, 0, version, 0 as little-endian 16-bit fields), or null.
     */
    static int[] vendorProductFromGUID(String guid) {
        if (guid == null || guid.length() < 20) return null;
        try {
            int vendor = Integer.parseInt(guid.substring(10, 12) + guid.substring(8, 10), 16);
            int product = Integer.parseInt(guid.substring(18, 20) + guid.substring(16, 18), 16);
            return (vendor == 0 && product == 0) ? null : new int[] {vendor, product};
        } catch (NumberFormatException e) {
            return null;
        }
    }

    // ---- Rumble ----

    /** Runs at the end of GLFWGamepadDriver.addComponents(controller). */
    public static void addComponents(int jid, Object controller) {
        try {
            if (!GLFW.amethystJoystickHasRumble(jid)) return;
            Api api = api(controller);
            Method setComponent = findSetComponent(controller.getClass(), api.rumbleComponentClass);
            if (setComponent == null) {
                log("no setComponent on " + controller.getClass().getName() + ", rumble disabled");
                return;
            }
            Object component = api.rumbleComponent.newInstance();
            setComponent.invoke(controller, component);
            rumbleComponents.put(controller, component);
            log("rumble enabled for joystick " + jid);
        } catch (Throwable t) {
            log("could not add rumble component: " + t);
        }
    }

    private static Method findSetComponent(Class<?> controllerClass, Class<?> componentClass) {
        for (Method method : controllerClass.getMethods()) {
            if (method.getName().equals("setComponent") && method.getParameterTypes().length == 1
                    && method.getParameterTypes()[0].isAssignableFrom(componentClass)) {
                return method;
            }
        }
        return null;
    }

    /** Runs at the start of GLFWGamepadDriver.update(controller, outOfFocus). */
    public static void update(int jid, Object controller) {
        Object component = rumbleComponents.get(controller);
        if (component == null) return;
        try {
            Optional<?> state = (Optional<?>) api(controller).consumeRumble.invoke(component);
            if (!state.isPresent()) return;
            Object rumble = state.get(); // RumbleState(float strong, float weak)
            float strong = (Float) rumble.getClass().getMethod("strong").invoke(rumble);
            float weak = (Float) rumble.getClass().getMethod("weak").invoke(rumble);
            GLFW.amethystSetJoystickRumble(jid, strong, weak);
        } catch (Throwable t) {
            // Never let rumble break input: drop rumble for this controller
            rumbleComponents.remove(controller);
            log("rumble disabled after error: " + t);
        }
    }
}
