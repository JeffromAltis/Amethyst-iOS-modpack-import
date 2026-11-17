package net.kdt.patchjna;

import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;

/** iPad integration for Controlify's existing public SDL/FFM API. */
public final class ControlifySDL {
    private ControlifySDL() {}
    // SDL_EventAction and event types from SDL_events.h (SDL 3.4)
    private static final int SDL_GETEVENT = 2;
    private static final int SDL_EVENT_JOYSTICK_ADDED = 0x605;
    private static final int SDL_EVENT_JOYSTICK_REMOVED = 0x606;
    private static volatile boolean filterSkipLogged;
    private static native void nativeRunOnMain(Runnable task);
    private static native void nativeControllerOwnership(boolean enabled);
    private static native void nativePrepareSDL();
    private static final class Session {
        Object delegate;
        Class<?> api;
        final List<Integer> initialized = new ArrayList<Integer>();
        void rollback() {
            if (delegate == null) return;
            try {
                Object init = api.getMethod("init").invoke(delegate);
                Method quit = api.getClassLoader().loadClass("dev.isxander.sdl.SdlInit").getMethod("SDL_QuitSubSystem", int.class);
                for (int i = initialized.size() - 1; i >= 0; i--) quit.invoke(init, initialized.get(i));
            } catch (Throwable failure) { System.err.println("[ControlifySDL] Startup cleanup failed: " + unwrap(failure)); }
        }
    }

    public static Object load(Class<?> owner) throws Throwable {
        String bundle = System.getenv("BUNDLE_PATH");
        if (bundle == null) throw new IllegalStateException("Missing Amethyst bundle path");
        System.load(bundle + "/AngelAuraAmethyst");
        final Object[] result = new Object[1];
        final Throwable[] failure = new Throwable[1];
        final Session session = new Session();
        nativeRunOnMain(() -> {
            nativeControllerOwnership(true);
            try {
                nativePrepareSDL();
                ClassLoader loader = owner.getClassLoader();
                Class<?> factory = Class.forName("dev.isxander.sdl.ffm.SdlFfmLoader", true, loader);
                Object delegate = factory.getMethod("create", Path.class).invoke(factory.getConstructor().newInstance(),
                        Paths.get(bundle, "Frameworks", "lwjgl34", "libSDL3.dylib"));
                Class<?> api = loader.loadClass("dev.isxander.sdl.Sdl");
                session.delegate = delegate;
                session.api = api;
                Object sdl = wrap(delegate, api, session);
                Method start = owner.getDeclaredMethod("startSdl", api);
                start.setAccessible(true);
                start.invoke(null, sdl);
                result[0] = sdl;
                System.out.println("[ControlifySDL] Existing FFM backend initialized with bundled SDL3 on UIKit thread");
            } catch (Throwable t) {
                failure[0] = unwrap(t);
                session.rollback();
                nativeControllerOwnership(false);
            }
        });
        if (failure[0] != null) throw failure[0];
        return result[0];
    }
    private static Throwable unwrap(Throwable t) {
        while (t instanceof InvocationTargetException) t = t.getCause();
        return t;
    }
    private static Object wrap(final Object delegate, Class<?> api, final Session session) {
        return Proxy.newProxyInstance(api.getClassLoader(), new Class<?>[]{api}, (proxy, method, args) -> {
            if (method.getDeclaringClass() == Object.class) {
                if ("equals".equals(method.getName())) return proxy == args[0];
                if ("hashCode".equals(method.getName())) return System.identityHashCode(proxy);
                return "Amethyst UIKit SDL proxy";
            }
            // Controlify sensor buffers can be views of a confined FFM arena.
            // Do not move those buffers to UIKit: buffer-taking gamepad and
            // joystick operations stay on their caller's thread.
            // In particular SDL_GetGamepadSensorData is explicitly thread-safe.
            String apiName = method.getDeclaringClass().getName();
            // Controlify loads its own SDL on desktop; here it shares the game's SDL (Minecraft 26.x reads its
            // keyboard and mouse from the same event queue). Controlify 3.5's event filter keeps only joystick
            // added/removed and so dropped every game input event, and its SDL_PollEvent would take the game's
            // events off the queue. Ignore the filter and let Controlify take only the events its filter kept.
            if (apiName.equals("dev.isxander.sdl.SdlEvents")) {
                String name = method.getName();
                if (name.equals("SDL_SetEventFilter")) {
                    if (!filterSkipLogged) {
                        filterSkipLogged = true;
                        System.out.println("[ControlifySDL] Ignoring Controlify's SDL event filter (SDL is shared with the game)");
                    }
                    return null;
                }
                if (name.equals("SDL_PollEvent") && args != null && args.length == 1 && args[0] != null) {
                    Object events = Array.newInstance(args[0].getClass(), 1);
                    Array.set(events, 0, args[0]);
                    Method peep = method.getDeclaringClass().getMethod("SDL_PeepEvents",
                            events.getClass(), int.class, int.class, int.class);
                    try {
                        int got = (Integer) peep.invoke(delegate, events, SDL_GETEVENT,
                                SDL_EVENT_JOYSTICK_ADDED, SDL_EVENT_JOYSTICK_REMOVED);
                        return got > 0;
                    } catch (InvocationTargetException failure) { throw unwrap(failure); }
                }
            }
            if (args != null && (apiName.equals("dev.isxander.sdl.SdlGamepad")
                    || apiName.equals("dev.isxander.sdl.SdlJoystick"))) {
                for (Object argument : args) if (argument instanceof java.nio.Buffer) {
                    try { return method.invoke(delegate, args); }
                    catch (InvocationTargetException failure) { throw unwrap(failure); }
                }
            }
            final Object[] result = new Object[1];
            final Throwable[] failure = new Throwable[1];
            nativeRunOnMain(() -> {
                try {
                    result[0] = method.invoke(delegate, args);
                    String name = method.getName();
                    if ((name.equals("SDL_Init") || name.equals("SDL_InitSubSystem")) && Boolean.TRUE.equals(result[0]))
                        session.initialized.add((Integer)args[0]);
                    if (name.equals("SDL_QuitSubSystem")) session.initialized.remove((Integer)args[0]);
                }
                catch (Throwable t) { failure[0] = unwrap(t); }
            });
            if (failure[0] != null) throw failure[0];
            Class<?> type = method.getReturnType();
            // Only subsystem interfaces are wrapped. Handles, callbacks and values retain their identity.
            if (method.getDeclaringClass().getName().equals("dev.isxander.sdl.Sdl")
                    && type.isInterface() && result[0] != null) return wrap(result[0], type, session);
            return result[0];
        });
    }
}
