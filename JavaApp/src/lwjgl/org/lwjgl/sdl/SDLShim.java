package org.lwjgl.sdl;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import org.lwjgl.BufferUtils;
import org.lwjgl.glfw.CallbackBridge;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.GL;
import org.lwjgl.system.Configuration;
import org.lwjgl.system.Library;
import org.lwjgl.system.SharedLibrary;
import org.lwjgl.system.macosx.MacOSXLibrary;

import static org.lwjgl.glfw.GLFW.*;
import static org.lwjgl.sdl.SDLEvents.*;
import static org.lwjgl.sdl.SDLKeycode.*;
import static org.lwjgl.sdl.SDLMouse.*;
import static org.lwjgl.sdl.SDLScancode.*;
import static org.lwjgl.sdl.SDLVideo.*;
import static org.lwjgl.system.JNI.*;
import static org.lwjgl.system.MemoryUtil.*;

/**
 * SDL3 for Amethyst iOS, implemented on top of the launcher's GLFW bridge.
 *
 * <p>lwjgl3ify 3.x (used by GT New Horizons on Java 9+) drives its window, GL context and input entirely
 * through SDL3. Amethyst iOS has no SDL: its game view, renderers and touch/keyboard/controller input all
 * go through its own GLFW implementation. This layer provides the part of the SDL3 API lwjgl3ify uses
 * (the {@code org.lwjgl.sdl} classes beside this one) and maps it onto that GLFW bridge:</p>
 * <ul>
 * <li>SDL windows are bookkeeping; the first one that gets a GL context becomes the GLFW window
 * (there is only one game view on iOS), further contexts are created shared and off-screen.</li>
 * <li>GLFW input callbacks, delivered while pumping, are translated into native {@code SDL_Event}s in a queue
 * that {@code SDL_PeepEvents} drains, with SDL3 keyboard semantics (scancodes, keycodes, modifiers,
 * keyboard state array, text input only between {@code SDL_StartTextInput} and {@code SDL_StopTextInput}).</li>
 * </ul>
 * <p>SDL's "main thread" is the thread that initialised SDL. lwjgl3ify does all video and event calls
 * there (RetroFuturaBootstrap's first-thread event loop); GLFW is initialised from it as well, which the
 * native bridge requires since it pumps events with the JNI environment of the initialising thread.</p>
 */
public final class SDLShim {

    private SDLShim() {}

    static final Object LOCK = new Object();
    private static final long START_NS = System.nanoTime();

    static long ticksNS() {
        return System.nanoTime() - START_NS;
    }

    // ---------------------------------------------------------------------------------------------
    // Errors and threads

    private static final ThreadLocal<String> ERROR = new ThreadLocal<String>() {
        @Override
        protected String initialValue() {
            return "";
        }
    };

    static boolean fail(String message) {
        ERROR.set(message);
        System.err.println("[SDLShim] " + message);
        return false;
    }

    static String getError() {
        return ERROR.get();
    }

    private static volatile Thread mainThread;
    private static boolean initialized;

    static void ensureMainThread() {
        if (mainThread == null) {
            mainThread = Thread.currentThread();
        }
    }

    static boolean isMainThread() {
        Thread main = mainThread;
        return main == null || main == Thread.currentThread();
    }

    static boolean init(int flags) {
        synchronized (LOCK) {
            ensureMainThread();
            if (initialized) {
                return true;
            }
            if (!glfwInit()) {
                return fail("Could not initialize the GLFW bridge");
            }
            installCallbacks();
            initialized = true;
            System.out.println("[SDLShim] SDL3 compatibility layer initialized on " + Thread.currentThread().getName());
            return true;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Hints and properties

    static final Map<String, String> HINTS = new HashMap<String, String>();
    private static final Map<Integer, Map<String, Object>> PROPERTIES = new HashMap<Integer, Map<String, Object>>();
    private static int nextProperties = 1;

    static int createProperties() {
        synchronized (LOCK) {
            int id = nextProperties++;
            PROPERTIES.put(id, new HashMap<String, Object>());
            return id;
        }
    }

    static void destroyProperties(int props) {
        synchronized (LOCK) {
            PROPERTIES.remove(props);
        }
    }

    static boolean setProperty(int props, CharSequence name, Object value) {
        synchronized (LOCK) {
            Map<String, Object> map = PROPERTIES.get(props);
            if (map == null || name == null) {
                return fail("Invalid properties");
            }
            map.put(name.toString(), value);
            return true;
        }
    }

    private static Object getProperty(int props, String name) {
        synchronized (LOCK) {
            Map<String, Object> map = PROPERTIES.get(props);
            return map == null ? null : map.get(name);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Windows

    static final class Window {
        final int id;
        final long handle;
        String title;
        int x, y, width, height;
        long flags;
        boolean shown;
        boolean textInput;
        boolean relativeMouse;
        /** GLFW bridge window, if this is the window shown on screen. */
        long glfwWindow;

        Window(int id) {
            this.id = id;
            // An opaque, non-null "SDL_Window *"
            this.handle = 0x5D1_0000_0000L | id;
        }
    }

    private static final Map<Long, Window> WINDOWS = new LinkedHashMap<Long, Window>();
    private static int nextWindowId = 1;
    /** The window drawn into the game view (the first one that got a GL context). */
    static volatile Window primary;

    static Window window(long handle) {
        synchronized (LOCK) {
            return WINDOWS.get(handle);
        }
    }

    static long createWindow(CharSequence title, int width, int height, long flags) {
        synchronized (LOCK) {
            ensureMainThread();
            Window window = new Window(nextWindowId++);
            window.title = title == null ? "" : title.toString();
            window.width = width > 0 ? width : GLFW.mGLFWWindowWidth;
            window.height = height > 0 ? height : GLFW.mGLFWWindowHeight;
            window.flags = flags;
            window.shown = (flags & SDL_WINDOW_HIDDEN) == 0;
            WINDOWS.put(window.handle, window);
            if (window.shown) {
                queueWindowShown(window);
            }
            return window.handle;
        }
    }

    static long createWindow(int props) {
        Object title = getProperty(props, SDL_PROP_WINDOW_CREATE_TITLE_STRING);
        long width = number(getProperty(props, SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER), 0);
        long height = number(getProperty(props, SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER), 0);
        long flags = number(getProperty(props, SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER), 0);
        if (bool(getProperty(props, SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN))) {
            flags |= SDL_WINDOW_HIDDEN;
        }
        if (bool(getProperty(props, SDL_PROP_WINDOW_CREATE_OPENGL_BOOLEAN))) {
            flags |= SDL_WINDOW_OPENGL;
        }
        if (bool(getProperty(props, SDL_PROP_WINDOW_CREATE_RESIZABLE_BOOLEAN))) {
            flags |= SDL_WINDOW_RESIZABLE;
        }
        if (bool(getProperty(props, SDL_PROP_WINDOW_CREATE_FULLSCREEN_BOOLEAN))) {
            flags |= SDL_WINDOW_FULLSCREEN;
        }
        return createWindow(title == null ? null : title.toString(), (int) width, (int) height, flags);
    }

    private static long number(Object value, long fallback) {
        return value instanceof Number ? ((Number) value).longValue() : fallback;
    }

    private static boolean bool(Object value) {
        return value instanceof Boolean && (Boolean) value;
    }

    static void destroyWindow(long handle) {
        synchronized (LOCK) {
            Window window = WINDOWS.remove(handle);
            if (window == null) {
                return;
            }
            if (window == primary) {
                primary = null;
            }
            // Contexts outliving their window can't be used anymore; keep the game view's bridge context
            Iterator<Map.Entry<Long, Context>> it = CONTEXTS.entrySet().iterator();
            while (it.hasNext()) {
                Context context = it.next().getValue();
                if (context.window == window) {
                    if (context.onScreen && context.nativeHandle != NULL) {
                        parkedContext = context.nativeHandle;
                    }
                    it.remove();
                }
            }
            window.glfwWindow = NULL;
        }
    }

    static boolean showWindow(long handle) {
        synchronized (LOCK) {
            Window window = WINDOWS.get(handle);
            if (window == null) {
                return fail("Invalid window");
            }
            if (!window.shown) {
                window.shown = true;
                window.flags &= ~SDL_WINDOW_HIDDEN;
                if (window.glfwWindow != 0) {
                    glfwShowWindow(window.glfwWindow);
                }
                queueWindowShown(window);
            }
            return true;
        }
    }

    private static void queueWindowShown(Window window) {
        queueWindowEvent(SDL_EVENT_WINDOW_SHOWN, window, 0, 0);
        queueWindowEvent(SDL_EVENT_WINDOW_EXPOSED, window, 0, 0);
        queueWindowEvent(SDL_EVENT_WINDOW_FOCUS_GAINED, window, 0, 0);
    }

    static long windowFlags(long handle) {
        Window window = window(handle);
        if (window == null) {
            return 0;
        }
        long flags = window.flags;
        if (window.shown) {
            flags |= SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_MOUSE_FOCUS;
        }
        if (window.relativeMouse) {
            flags |= SDL_WINDOW_MOUSE_RELATIVE_MODE;
        }
        return flags;
    }

    /** The window size; the on-screen window always matches the game view. */
    static int windowWidth(Window window) {
        return window == primary ? GLFW.mGLFWWindowWidth : window.width;
    }

    static int windowHeight(Window window) {
        return window == primary ? GLFW.mGLFWWindowHeight : window.height;
    }

    // ---------------------------------------------------------------------------------------------
    // OpenGL

    private static final int GL_ATTRIBUTE_COUNT = 64;
    private static final int[] GL_ATTRIBUTES = new int[GL_ATTRIBUTE_COUNT];

    static {
        resetGLAttributes();
    }

    static void resetGLAttributes() {
        synchronized (LOCK) {
            java.util.Arrays.fill(GL_ATTRIBUTES, 0);
            GL_ATTRIBUTES[SDL_GL_RED_SIZE] = 8;
            GL_ATTRIBUTES[SDL_GL_GREEN_SIZE] = 8;
            GL_ATTRIBUTES[SDL_GL_BLUE_SIZE] = 8;
            GL_ATTRIBUTES[SDL_GL_DEPTH_SIZE] = 16;
            GL_ATTRIBUTES[SDL_GL_DOUBLEBUFFER] = 1;
            GL_ATTRIBUTES[SDL_GL_CONTEXT_MAJOR_VERSION] = 2;
            GL_ATTRIBUTES[SDL_GL_CONTEXT_MINOR_VERSION] = 1;
        }
    }

    static boolean setGLAttribute(int attr, int value) {
        if (attr < 0 || attr >= GL_ATTRIBUTE_COUNT) {
            return fail("Unknown OpenGL attribute " + attr);
        }
        synchronized (LOCK) {
            GL_ATTRIBUTES[attr] = value;
        }
        return true;
    }

    /**
     * An SDL_GLContext. The bridge context behind it is created lazily, on the first thread that makes it
     * current other than SDL's main thread: the bridge (and the renderers behind it, MobileGlues over ANGLE)
     * only works when a context is created and used on the same thread, which is how every other game on
     * Amethyst uses it. lwjgl3ify creates contexts on its event thread (SDL's main thread) but renders on
     * the game thread and never calls GL on the event thread, so make-current calls there are bookkeeping.
     */
    static final class Context {
        final long handle;
        final Window window;
        final boolean onScreen;
        final Context share;
        final int major, minor;
        /** The bridge context, NULL until a rendering thread makes this context current. */
        long nativeHandle;

        Context(long handle, Window window, boolean onScreen, Context share, int major, int minor) {
            this.handle = handle;
            this.window = window;
            this.onScreen = onScreen;
            this.share = share;
            this.major = major;
            this.minor = minor;
        }
    }

    private static final Map<Long, Context> CONTEXTS = new HashMap<Long, Context>();
    private static int nextContext = 1;
    /** What SDL considers current on each thread: window, context. */
    private static final ThreadLocal<long[]> CURRENT = new ThreadLocal<long[]>() {
        @Override
        protected long[] initialValue() {
            return new long[2];
        }
    };
    /** The bridge context actually current on each thread. */
    private static final ThreadLocal<long[]> NATIVE_CURRENT = new ThreadLocal<long[]>() {
        @Override
        protected long[] initialValue() {
            return new long[1];
        }
    };

    /**
     * The game view's bridge context once its SDL context or window was destroyed. The bridge draws every
     * context onto the one game view surface and cannot create a second surface there (EGL_BAD_ALLOC),
     * nor does it free contexts. So when the game recreates its display (Angelica does, to probe GL
     * versions), the new on-screen context gets this one back instead of a new one.
     */
    private static long parkedContext = NULL;

    private static boolean onSdlMainThread() {
        return mainThread != null && mainThread == Thread.currentThread();
    }

    static long createContext(long handle) {
        synchronized (LOCK) {
            Window window = WINDOWS.get(handle);
            if (window == null) {
                fail("Invalid window");
                return NULL;
            }
            if (!initialized) {
                init(0);
            }
            // The game view gets the on-screen context: the first window to ask (later ones, like
            // lwjgl3ify's hidden helper window, get shared off-screen contexts)
            boolean onScreen = primary == null || window == primary;
            if (onScreen) {
                primary = window;
            }
            Context share = GL_ATTRIBUTES[SDL_GL_SHARE_WITH_CURRENT_CONTEXT] != 0 ? CONTEXTS.get(CURRENT.get()[1]) : null;
            long id = 0x5DC7_0000_0000L | nextContext++;
            Context context = new Context(id, window, onScreen, share,
                GL_ATTRIBUTES[SDL_GL_CONTEXT_MAJOR_VERSION], GL_ATTRIBUTES[SDL_GL_CONTEXT_MINOR_VERSION]);
            CONTEXTS.put(id, context);
            // SDL makes a new context current on the calling thread
            if (!makeCurrent(handle, id)) {
                CONTEXTS.remove(id);
                return NULL;
            }
            return id;
        }
    }

    /** Creates the bridge context behind an SDL context. Called on the thread that will render with it. */
    private static boolean realize(Context context) {
        synchronized (LOCK) {
            if (context.nativeHandle != NULL) {
                return true;
            }
            // Let the bridge pick the renderer the way it does for GLFW games (gl4es for GL 1.x/2.x
            // when the profile's renderer is "auto", MobileGlues for newer requests)
            glfwWindowHint(GLFW_CLIENT_API, GLFW_OPENGL_API);
            glfwWindowHint(GLFW_CONTEXT_VERSION_MAJOR, context.major);
            glfwWindowHint(GLFW_CONTEXT_VERSION_MINOR, context.minor);
            long share = context.share != null ? context.share.nativeHandle : NULL;
            long nativeHandle;
            if (context.onScreen) {
                if (parkedContext != NULL) {
                    nativeHandle = parkedContext;
                    parkedContext = NULL;
                    System.out.println("[SDLShim] Reusing the game view's OpenGL context for the new window");
                } else {
                    // A real GLFW bridge window, so it receives input and resize events
                    nativeHandle = glfwCreateWindow(GLFW.mGLFWWindowWidth, GLFW.mGLFWWindowHeight, context.window.title, NULL, share);
                    System.out.println("[SDLShim] Created the game view's OpenGL context on " + Thread.currentThread().getName());
                }
                if (nativeHandle == NULL) {
                    return fail("Could not create an OpenGL context");
                }
                Window window = context.window;
                window.glfwWindow = nativeHandle;
                if (window.shown) {
                    glfwShowWindow(nativeHandle);
                }
                if (window.relativeMouse) {
                    glfwSetInputMode(nativeHandle, GLFW_CURSOR, GLFW_CURSOR_DISABLED);
                }
            } else {
                // Extra (shared, off-screen) contexts stay out of the GLFW window list, or every
                // input event would be delivered once per window
                nativeHandle = GLFW.nglfwCreateContext(share);
                if (nativeHandle == NULL) {
                    return fail("Could not create a secondary OpenGL context");
                }
            }
            context.nativeHandle = nativeHandle;
            return true;
        }
    }

    static boolean destroyContext(long handle) {
        synchronized (LOCK) {
            Context context = CONTEXTS.remove(handle);
            long[] current = CURRENT.get();
            if (current[1] == handle) {
                current[0] = NULL;
                current[1] = NULL;
            }
            if (context == null) {
                return true;
            }
            long[] nativeCurrent = NATIVE_CURRENT.get();
            if (context.nativeHandle != NULL && nativeCurrent[0] == context.nativeHandle) {
                glfwMakeContextCurrent(NULL);
                nativeCurrent[0] = NULL;
            }
            // The bridge keeps its contexts until the game exits; the on-screen one is reused
            if (context.onScreen && context.nativeHandle != NULL) {
                parkedContext = context.nativeHandle;
                if (context.window.glfwWindow == context.nativeHandle) {
                    context.window.glfwWindow = NULL;
                }
            }
            return true;
        }
    }

    static boolean makeCurrent(long window, long handle) {
        long[] current = CURRENT.get();
        long[] nativeCurrent = NATIVE_CURRENT.get();
        if (handle == NULL) {
            current[0] = NULL;
            current[1] = NULL;
            // The bridge sets up its renderer (and the function it releases contexts with) only when the
            // first context is created, so only release what this thread really has current
            if (nativeCurrent[0] != NULL) {
                glfwMakeContextCurrent(NULL);
                nativeCurrent[0] = NULL;
            }
            return true;
        }
        Context context;
        synchronized (LOCK) {
            context = CONTEXTS.get(handle);
        }
        if (context == null) {
            return fail("Invalid OpenGL context");
        }
        current[0] = window;
        current[1] = handle;
        if (onSdlMainThread()) {
            // Bookkeeping only, see Context
            return true;
        }
        if (!realize(context)) {
            current[0] = NULL;
            current[1] = NULL;
            return false;
        }
        if (nativeCurrent[0] != context.nativeHandle) {
            glfwMakeContextCurrent(context.nativeHandle);
            nativeCurrent[0] = context.nativeHandle;
        }
        return true;
    }

    static long currentContext() {
        return CURRENT.get()[1];
    }

    static long currentWindow() {
        return CURRENT.get()[0];
    }

    private static volatile int requestedSwapInterval = Integer.MIN_VALUE;
    private static int appliedSwapInterval = Integer.MIN_VALUE;

    static boolean setSwapInterval(int interval) {
        // lwjgl3ify sets vsync from its event thread, where no bridge context is current. Apply it from
        // the rendering thread instead.
        requestedSwapInterval = interval;
        if (NATIVE_CURRENT.get()[0] != NULL) {
            applySwapInterval();
        }
        return true;
    }

    private static void applySwapInterval() {
        int requested = requestedSwapInterval;
        if (requested != Integer.MIN_VALUE && requested != appliedSwapInterval) {
            glfwSwapInterval(requested < 0 ? 1 : requested);
            appliedSwapInterval = requested;
        }
    }

    static boolean swapWindow(long handle) {
        Window window = window(handle);
        if (window == null) {
            return fail("Invalid window");
        }
        long nativeCurrent = NATIVE_CURRENT.get()[0];
        if (nativeCurrent == NULL) {
            return fail("No OpenGL context is current on this thread");
        }
        applySwapInterval();
        glfwSwapBuffers(window.glfwWindow != NULL ? window.glfwWindow : nativeCurrent);
        return true;
    }

    private static SharedLibrary glLibrary;
    private static long osMesaGetProcAddress;

    static boolean loadGLLibrary() {
        synchronized (LOCK) {
            if (glLibrary != null) {
                return true;
            }
            try {
                // Same lookup as LWJGL's GL.create() on Amethyst: the renderer the bridge selected
                // (org.lwjgl.opengl.libname is updated by it when the context is created)
                String name = System.getProperty("org.lwjgl.opengl.libname");
                Configuration.OPENGL_LIBRARY_NAME.set(name);
                glLibrary = name != null
                    ? Library.loadNative(GL.class, "org.lwjgl.opengl", name)
                    : MacOSXLibrary.getWithIdentifier("com.apple.opengl");
                osMesaGetProcAddress = glLibrary.getFunctionAddress("OSMesaGetProcAddress");
                System.out.println("[SDLShim] Loaded OpenGL library " + glLibrary.getName());
                return true;
            } catch (Throwable t) {
                t.printStackTrace();
                return fail("Could not load the OpenGL library: " + t);
            }
        }
    }

    static long getProcAddress(ByteBuffer name) {
        if (glLibrary == null && !loadGLLibrary()) {
            return NULL;
        }
        long address = NULL;
        if (osMesaGetProcAddress != NULL) {
            address = callPP(memAddress(name), osMesaGetProcAddress);
        }
        if (address == NULL) {
            address = glLibrary.getFunctionAddress(name);
        }
        if (address != NULL && "glGetFloatv".equals(memASCII(memAddress(name)))) {
            address = hookGetFloatv(address);
        }
        return address;
    }

    /**
     * Hands out the launcher's glGetFloatv (Natives/sdl_gl_hooks.c), which reports a usable wide-line
     * range: ANGLE's honest [1, 1] makes Angelica emulate wide lines with geometry shaders, which OpenGL
     * ES doesn't have. Falls back to the renderer's own function if the hook isn't in this build.
     */
    private static long hookGetFloatv(long real) {
        try {
            SharedLibrary launcher = GLFW.getLibrary();
            long setReal = launcher.getFunctionAddress("amethyst_sdl_setRealGlGetFloatv");
            long hook = launcher.getFunctionAddress("amethyst_sdl_glGetFloatv");
            if (setReal == NULL || hook == NULL) {
                return real;
            }
            invokePV(real, setReal);
            return hook;
        } catch (Throwable t) {
            System.err.println("[SDLShim] Could not install the glGetFloatv hook: " + t);
            return real;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Display

    private static SDL_DisplayMode desktopMode;
    private static org.lwjgl.PointerBuffer fullscreenModes;

    static SDL_DisplayMode desktopMode() {
        synchronized (LOCK) {
            if (desktopMode == null) {
                desktopMode = SDL_DisplayMode.calloc();
                fullscreenModes = memAllocPointer(1);
            }
            int refresh = 60;
            try {
                refresh = Integer.parseInt(System.getProperty("UIScreen.maximumFramesPerSecond", "60"));
            } catch (NumberFormatException ignored) {}
            desktopMode
                .displayID(1)
                .format(SDLPixels.SDL_PIXELFORMAT_ARGB8888)
                .w(GLFW.mGLFWWindowWidth)
                .h(GLFW.mGLFWWindowHeight)
                .pixel_density(1.0f)
                .refresh_rate(refresh)
                .refresh_rate_numerator(refresh)
                .refresh_rate_denominator(1);
            fullscreenModes.put(0, desktopMode.address());
            return desktopMode;
        }
    }

    static org.lwjgl.PointerBuffer fullscreenModes() {
        desktopMode();
        return fullscreenModes;
    }

    private static final Map<Integer, SDL_PixelFormatDetails> FORMAT_DETAILS = new HashMap<Integer, SDL_PixelFormatDetails>();

    static SDL_PixelFormatDetails formatDetails(int format) {
        synchronized (LOCK) {
            SDL_PixelFormatDetails details = FORMAT_DETAILS.get(format);
            if (details == null) {
                int bits = SDLPixels.SDL_BITSPERPIXEL(format);
                int bytes = SDLPixels.SDL_BYTESPERPIXEL(format);
                long address = nmemCallocChecked(1, SDL_PixelFormatDetails.SIZEOF);
                details = SDL_PixelFormatDetails.create(address);
                // A read-only struct in LWJGL (SDL fills it in), so write the fields directly
                memPutInt(address + SDL_PixelFormatDetails.FORMAT, format);
                memPutByte(address + SDL_PixelFormatDetails.BITS_PER_PIXEL, (byte) bits);
                memPutByte(address + SDL_PixelFormatDetails.BYTES_PER_PIXEL, (byte) bytes);
                FORMAT_DETAILS.put(format, details);
            }
            return details;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Surfaces (window icons and cursors; the game view shows neither, but lwjgl3ify builds them)

    private static final Map<Long, List<SDL_Surface>> ALTERNATE_IMAGES = new HashMap<Long, List<SDL_Surface>>();

    static SDL_Surface createSurface(int width, int height, int format) {
        int bytes = Math.max(1, SDLPixels.SDL_BYTESPERPIXEL(format));
        int pitch = width * bytes;
        long pixels = nmemCalloc(1, (long) pitch * Math.max(1, height));
        SDL_Surface surface = SDL_Surface.calloc();
        long address = surface.address();
        SDL_Surface.nformat(address, format);
        SDL_Surface.nw(address, width);
        SDL_Surface.nh(address, height);
        SDL_Surface.npitch(address, pitch);
        memPutAddress(address + SDL_Surface.PIXELS, pixels);
        SDL_Surface.nrefcount(address, 1);
        return surface;
    }

    static void destroySurface(SDL_Surface surface) {
        if (surface == null) {
            return;
        }
        List<SDL_Surface> alternates;
        synchronized (LOCK) {
            alternates = ALTERNATE_IMAGES.remove(surface.address());
        }
        if (alternates != null) {
            for (SDL_Surface alternate : alternates) {
                destroySurface(alternate);
            }
        }
        nmemFree(memGetAddress(surface.address() + SDL_Surface.PIXELS));
        surface.free();
    }

    static boolean addAlternateImage(SDL_Surface surface, SDL_Surface image) {
        synchronized (LOCK) {
            List<SDL_Surface> list = ALTERNATE_IMAGES.get(surface.address());
            if (list == null) {
                list = new ArrayList<SDL_Surface>();
                ALTERNATE_IMAGES.put(surface.address(), list);
            }
            // SDL takes a reference; the caller still destroys its own copy
            SDL_Surface copy = createSurface(image.w(), image.h(), image.format());
            memCopy(memGetAddress(image.address() + SDL_Surface.PIXELS),
                memGetAddress(copy.address() + SDL_Surface.PIXELS), (long) image.pitch() * image.h());
            list.add(copy);
            return true;
        }
    }

    static boolean flipSurface(SDL_Surface surface, int flip) {
        long pixels = memGetAddress(surface.address() + SDL_Surface.PIXELS);
        int width = surface.w(), height = surface.h(), pitch = surface.pitch();
        int bytes = Math.max(1, SDLPixels.SDL_BYTESPERPIXEL(surface.format()));
        if ((flip & SDLSurface.SDL_FLIP_VERTICAL) != 0) {
            long row = nmemAlloc(pitch);
            for (int y = 0; y < height / 2; y++) {
                long top = pixels + (long) y * pitch, bottom = pixels + (long) (height - 1 - y) * pitch;
                memCopy(top, row, pitch);
                memCopy(bottom, top, pitch);
                memCopy(row, bottom, pitch);
            }
            nmemFree(row);
        }
        if ((flip & SDLSurface.SDL_FLIP_HORIZONTAL) != 0) {
            long pixel = nmemAlloc(bytes);
            for (int y = 0; y < height; y++) {
                long line = pixels + (long) y * pitch;
                for (int x = 0; x < width / 2; x++) {
                    long left = line + (long) x * bytes, right = line + (long) (width - 1 - x) * bytes;
                    memCopy(left, pixel, bytes);
                    memCopy(right, left, bytes);
                    memCopy(pixel, right, bytes);
                }
            }
            nmemFree(pixel);
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Event queue

    private static final int MAX_QUEUED_EVENTS = 65536;
    private static final ArrayDeque<Long> QUEUE = new ArrayDeque<Long>();
    private static final ArrayDeque<Long> FREE_EVENTS = new ArrayDeque<Long>();
    /** Text of delivered SDL_EVENT_TEXT_INPUT events stays valid until the next pump, as in SDL. */
    private static final List<ByteBuffer> DELIVERED_TEXT = new ArrayList<ByteBuffer>();
    private static final List<ByteBuffer> QUEUED_TEXT = new ArrayList<ByteBuffer>();

    /** Returns a zeroed event slot to fill in, or NULL if the queue is full. */
    private static long newEvent(int type) {
        synchronized (QUEUE) {
            if (QUEUE.size() >= MAX_QUEUED_EVENTS) {
                return NULL;
            }
            Long slot = FREE_EVENTS.poll();
            long address = slot != null ? slot : nmemAlloc(SDL_Event.SIZEOF);
            memSet(address, 0, SDL_Event.SIZEOF);
            SDL_CommonEvent.ntype(address, type);
            SDL_CommonEvent.ntimestamp(address, ticksNS());
            return address;
        }
    }

    private static void pushEvent(long address) {
        if (address != NULL) {
            synchronized (QUEUE) {
                QUEUE.add(address);
            }
        }
    }

    static int peepEvents(SDL_Event.Buffer events, int numevents, int action, int minType, int maxType) {
        synchronized (QUEUE) {
            if (action == SDL_ADDEVENT) {
                int added = 0;
                for (int i = 0; i < numevents && events != null; i++) {
                    long event = newEvent(SDL_CommonEvent.ntype(events.address(i)));
                    if (event == NULL) {
                        break;
                    }
                    memCopy(events.address(i), event, SDL_Event.SIZEOF);
                    pushEvent(event);
                    added++;
                }
                return added;
            }
            int count = 0;
            Iterator<Long> it = QUEUE.iterator();
            while (it.hasNext() && (events == null || count < numevents)) {
                long event = it.next();
                int type = SDL_CommonEvent.ntype(event);
                if (type < minType || type > maxType) {
                    continue;
                }
                if (events != null) {
                    memCopy(event, events.address(count), SDL_Event.SIZEOF);
                }
                if (action == SDL_GETEVENT) {
                    it.remove();
                    FREE_EVENTS.add(event);
                }
                count++;
            }
            if (action == SDL_GETEVENT && QUEUE.isEmpty()) {
                // Text belonging to the events just handed out stays alive until the next pump
                DELIVERED_TEXT.addAll(QUEUED_TEXT);
                QUEUED_TEXT.clear();
            }
            return count;
        }
    }

    static void pumpEvents() {
        synchronized (QUEUE) {
            for (ByteBuffer text : DELIVERED_TEXT) {
                memFree(text);
            }
            DELIVERED_TEXT.clear();
        }
        if (!initialized) {
            return;
        }
        // Delivers the bridge's queued input to the callbacks below, on this thread. Under LOCK: the game
        // thread may be adding the game view to the bridge's window list at the same time.
        synchronized (LOCK) {
            glfwPollEvents();
        }
    }

    private static int windowId(long glfwWindow) {
        Window window = primary;
        return window != null ? window.id : 0;
    }

    private static void queueWindowEvent(int type, Window window, int data1, int data2) {
        long event = newEvent(type);
        if (event == NULL) {
            return;
        }
        SDL_WindowEvent.nwindowID(event, window.id);
        SDL_WindowEvent.ndata1(event, data1);
        SDL_WindowEvent.ndata2(event, data2);
        pushEvent(event);
    }

    // ---------------------------------------------------------------------------------------------
    // Keyboard

    private static final ByteBuffer KEYBOARD_STATE = BufferUtils.createByteBuffer(SDL_SCANCODE_COUNT);
    private static volatile short modState;

    static ByteBuffer keyboardState() {
        return KEYBOARD_STATE;
    }

    static boolean setTextInput(long handle, boolean enabled) {
        Window window = window(handle);
        if (window == null) {
            return fail("Invalid window");
        }
        window.textInput = enabled;
        return true;
    }

    private static void onKey(long glfwWindow, int glfwKey, int glfwScancode, int action, int glfwMods) {
        int scancode = SDLKeys.glfwKeyToScancode(glfwKey);
        if (scancode == SDL_SCANCODE_UNKNOWN) {
            return;
        }
        boolean down = action != GLFW_RELEASE;
        KEYBOARD_STATE.put(scancode, (byte) (down ? 1 : 0));

        int mod = SDLKeys.modifierForScancode(scancode);
        if (scancode == SDL_SCANCODE_CAPSLOCK) {
            if (action == GLFW_PRESS) {
                modState ^= SDL_KMOD_CAPS;
            }
        } else if (scancode == SDL_SCANCODE_NUMLOCKCLEAR) {
            if (action == GLFW_PRESS) {
                modState ^= SDL_KMOD_NUM;
            }
        } else if (mod != 0) {
            modState = (short) (down ? (modState | mod) : (modState & ~mod));
        }

        long event = newEvent(down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP);
        if (event == NULL) {
            return;
        }
        SDL_KeyboardEvent.nwindowID(event, windowId(glfwWindow));
        SDL_KeyboardEvent.nscancode(event, scancode);
        SDL_KeyboardEvent.nkey(event, SDLKeys.keyFromScancode(scancode, modState, true));
        SDL_KeyboardEvent.nmod(event, modState);
        SDL_KeyboardEvent.nraw(event, (short) glfwScancode);
        SDL_KeyboardEvent.ndown(event, down);
        SDL_KeyboardEvent.nrepeat(event, action == GLFW_REPEAT);
        pushEvent(event);
    }

    private static void onChar(long glfwWindow, int codepoint) {
        Window window = primary;
        if (window == null || !window.textInput || codepoint <= 0) {
            return;
        }
        String text = new String(Character.toChars(codepoint));
        long event = newEvent(SDL_EVENT_TEXT_INPUT);
        if (event == NULL) {
            return;
        }
        ByteBuffer utf8 = memUTF8(text, true);
        synchronized (QUEUE) {
            QUEUED_TEXT.add(utf8);
        }
        SDL_TextInputEvent.nwindowID(event, window.id);
        memPutAddress(event + SDL_TextInputEvent.TEXT, memAddress(utf8));
        pushEvent(event);
    }

    // ---------------------------------------------------------------------------------------------
    // Mouse

    private static volatile float mouseX = Float.NaN, mouseY = Float.NaN;
    private static volatile int mouseButtons;

    static int mouseState(long x, long y) {
        if (x != NULL) {
            memPutFloat(x, Float.isNaN(mouseX) ? 0 : mouseX);
        }
        if (y != NULL) {
            memPutFloat(y, Float.isNaN(mouseY) ? 0 : mouseY);
        }
        return mouseButtons;
    }

    static boolean setRelativeMouseMode(long handle, boolean enabled) {
        Window window = window(handle);
        if (window == null) {
            return fail("Invalid window");
        }
        window.relativeMouse = enabled;
        if (window.glfwWindow != NULL) {
            glfwSetInputMode(window.glfwWindow, GLFW_CURSOR, enabled ? GLFW_CURSOR_DISABLED : GLFW_CURSOR_NORMAL);
        }
        return true;
    }

    static void warpMouse(long handle, float x, float y) {
        Window window = window(handle);
        if (window == null || window.glfwWindow == NULL) {
            return;
        }
        // The bridge reports the warp as a motion on the next pump; it is not a user movement
        mouseX = x;
        mouseY = y;
        glfwSetCursorPos(window.glfwWindow, x, y);
    }

    private static void onCursorPos(long glfwWindow, double x, double y) {
        float fx = (float) x, fy = (float) y;
        boolean first = Float.isNaN(mouseX) || Float.isNaN(mouseY);
        float dx = first ? 0 : fx - mouseX;
        float dy = first ? 0 : fy - mouseY;
        mouseX = fx;
        mouseY = fy;
        // Nothing moved (e.g. the bridge echoing a warp): not a motion. The first report always is,
        // since it establishes where the cursor is.
        if (!first && dx == 0 && dy == 0) {
            return;
        }
        long event = newEvent(SDL_EVENT_MOUSE_MOTION);
        if (event == NULL) {
            return;
        }
        SDL_MouseMotionEvent.nwindowID(event, windowId(glfwWindow));
        SDL_MouseMotionEvent.nstate(event, mouseButtons);
        SDL_MouseMotionEvent.nx(event, fx);
        SDL_MouseMotionEvent.ny(event, fy);
        SDL_MouseMotionEvent.nxrel(event, dx);
        SDL_MouseMotionEvent.nyrel(event, dy);
        pushEvent(event);
    }

    private static void onMouseButton(long glfwWindow, int glfwButton, int action, int mods) {
        int button;
        switch (glfwButton) {
            case GLFW_MOUSE_BUTTON_LEFT: button = SDL_BUTTON_LEFT; break;
            case GLFW_MOUSE_BUTTON_RIGHT: button = SDL_BUTTON_RIGHT; break;
            case GLFW_MOUSE_BUTTON_MIDDLE: button = SDL_BUTTON_MIDDLE; break;
            case GLFW_MOUSE_BUTTON_4: button = SDL_BUTTON_X1; break;
            case GLFW_MOUSE_BUTTON_5: button = SDL_BUTTON_X2; break;
            default: return;
        }
        boolean down = action != GLFW_RELEASE;
        int mask = 1 << (button - 1);
        mouseButtons = down ? (mouseButtons | mask) : (mouseButtons & ~mask);

        long event = newEvent(down ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP);
        if (event == NULL) {
            return;
        }
        SDL_MouseButtonEvent.nwindowID(event, windowId(glfwWindow));
        SDL_MouseButtonEvent.nbutton(event, (byte) button);
        SDL_MouseButtonEvent.ndown(event, down);
        SDL_MouseButtonEvent.nclicks(event, (byte) 1);
        SDL_MouseButtonEvent.nx(event, Float.isNaN(mouseX) ? 0 : mouseX);
        SDL_MouseButtonEvent.ny(event, Float.isNaN(mouseY) ? 0 : mouseY);
        pushEvent(event);
    }

    private static void onScroll(long glfwWindow, double x, double y) {
        long event = newEvent(SDL_EVENT_MOUSE_WHEEL);
        if (event == NULL) {
            return;
        }
        SDL_MouseWheelEvent.nwindowID(event, windowId(glfwWindow));
        SDL_MouseWheelEvent.nx(event, (float) x);
        SDL_MouseWheelEvent.ny(event, (float) y);
        SDL_MouseWheelEvent.ndirection(event, SDL_MOUSEWHEEL_NORMAL);
        SDL_MouseWheelEvent.nmouse_x(event, Float.isNaN(mouseX) ? 0 : mouseX);
        SDL_MouseWheelEvent.nmouse_y(event, Float.isNaN(mouseY) ? 0 : mouseY);
        SDL_MouseWheelEvent.ninteger_x(event, (int) x);
        SDL_MouseWheelEvent.ninteger_y(event, (int) y);
        pushEvent(event);
    }

    // ---------------------------------------------------------------------------------------------
    // Window size

    private static int lastWidth, lastHeight;

    private static void onSize(long glfwWindow, int width, int height) {
        Window window = primary;
        if (window == null || width <= 0 || height <= 0 || (width == lastWidth && height == lastHeight)) {
            return;
        }
        lastWidth = width;
        lastHeight = height;
        window.width = width;
        window.height = height;
        queueWindowEvent(SDL_EVENT_WINDOW_RESIZED, window, width, height);
        queueWindowEvent(SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, window, width, height);
    }

    // ---------------------------------------------------------------------------------------------
    // GLFW bridge callbacks (invoked while pumping, on the SDL main thread)

    private static void installCallbacks() {
        glfwSetKeyCallback(NULL, SDLShim::onKey);
        glfwSetCharCallback(NULL, SDLShim::onChar);
        glfwSetCursorPosCallback(NULL, SDLShim::onCursorPos);
        glfwSetMouseButtonCallback(NULL, SDLShim::onMouseButton);
        glfwSetScrollCallback(NULL, SDLShim::onScroll);
        glfwSetWindowSizeCallback(NULL, SDLShim::onSize);
        glfwSetFramebufferSizeCallback(NULL, SDLShim::onSize);
    }

    // ---------------------------------------------------------------------------------------------
    // Clipboard

    static boolean setClipboard(ByteBuffer utf8) {
        byte[] bytes;
        if (utf8 == null) {
            bytes = new byte[0];
        } else {
            ByteBuffer copy = utf8.duplicate();
            int length = 0;
            while (length < copy.remaining() && copy.get(copy.position() + length) != 0) {
                length++;
            }
            bytes = new byte[length];
            copy.get(bytes);
        }
        CallbackBridge.nativeClipboard(CallbackBridge.CLIPBOARD_COPY, bytes);
        return true;
    }

    static boolean setClipboard(CharSequence text) {
        byte[] bytes = text == null ? new byte[0] : text.toString().getBytes(StandardCharsets.UTF_8);
        CallbackBridge.nativeClipboard(CallbackBridge.CLIPBOARD_COPY, bytes);
        return true;
    }

    static String getClipboard() {
        String text = CallbackBridge.nativeClipboard(CallbackBridge.CLIPBOARD_PASTE, null);
        return text == null ? "" : text;
    }
}
