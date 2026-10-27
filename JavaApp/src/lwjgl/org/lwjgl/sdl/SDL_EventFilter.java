package org.lwjgl.sdl;

import org.lwjgl.system.NativeResource;

/**
 * Event filter callback. LWJGL's version is a native callback stub; the SDL3 compatibility layer
 * (see {@link SDLShim}) dispatches events in Java, so this only wraps the Java callback, with the
 * same {@code create}/{@code free} surface that code written against LWJGL uses.
 */
public final class SDL_EventFilter implements SDL_EventFilterI, NativeResource {

    private final SDL_EventFilterI delegate;

    private SDL_EventFilter(SDL_EventFilterI delegate) {
        this.delegate = delegate;
    }

    public static SDL_EventFilter create(SDL_EventFilterI instance) {
        return instance instanceof SDL_EventFilter ? (SDL_EventFilter) instance : new SDL_EventFilter(instance);
    }

    public static SDL_EventFilter createSafe(SDL_EventFilterI instance) {
        return instance == null ? null : create(instance);
    }

    @Override
    public boolean invoke(long userdata, long event) {
        return delegate.invoke(userdata, event);
    }

    @Override
    public void free() {
        // Nothing native to release
    }
}
