import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;

/** Standalone FFM probe. Does not initialize SDL subsystems or open controllers. */
public final class SDLBindingProbe {
    private static PrintWriter log;
    private static void stage(String text) {
        System.out.println("[SDL binding probe] " + text);
        if (log != null) { log.println(text); log.flush(); }
    }
    public static void main(String[] args) throws Exception {
        Path report = Paths.get(System.getProperty("user.home"), "sdl-binding-probe.log");
        log = new PrintWriter(Files.newBufferedWriter(report));
        try {
            stage("Java: " + System.getProperty("java.version") + "; "
                    + System.getProperty("os.name") + "; " + System.getProperty("os.arch"));
            stage("Report: " + report);
            Path library = findSDL();
            stage("SDL library: " + library);
            stage("Creating the Java FFM native linker");
            Class.forName("java.lang.foreign.Linker").getMethod("nativeLinker").invoke(null);
            stage("Native linker created");
            List<URL> jars = new ArrayList<URL>();
            for (String name : new String[]{"sdl-api.jar", "sdl-ffm.jar"}) {
                Path temp = Files.createTempFile("amethyst-sdl-probe-", ".jar");
                temp.toFile().deleteOnExit();
                try (InputStream input = SDLBindingProbe.class.getResourceAsStream("/" + name)) {
                    if (input == null) throw new IOException("Missing embedded " + name);
                    Files.copy(input, temp, StandardCopyOption.REPLACE_EXISTING);
                }
                jars.add(temp.toUri().toURL());
            }
            try (URLClassLoader loader = new URLClassLoader(jars.toArray(new URL[0]), SDLBindingProbe.class.getClassLoader())) {
                stage("Creating the unchanged Controlify FFM backend with the explicit SDL path");
                Class<?> factory = loader.loadClass("dev.isxander.sdl.ffm.SdlFfmLoader");
                Object sdl = factory.getMethod("create", Path.class).invoke(factory.getConstructor().newInstance(), library);
                stage("Backend created; calling SDL_GetVersion");
                Object version = loader.loadClass("dev.isxander.sdl.Sdl").getMethod("version").invoke(sdl);
                Object value = loader.loadClass("dev.isxander.sdl.SdlVersion").getMethod("SDL_GetVersion").invoke(version);
                stage("PASS: native SDL version = " + value);
                if (SDLBindingProbe.class.getResource("/probe-callbacks") != null) {
                    testCallback(loader, sdl);
                }
                if (SDLBindingProbe.class.getResource("/probe-controllers") != null) {
                    System.setProperty("amethyst.probe.resolvedSDL", library.toString());
                    testControllers(loader, sdl);
                } else stage("SDL subsystem initialization and controller input remain untested.");
            }
        } catch (Throwable failure) {
            while (failure instanceof InvocationTargetException) failure = failure.getCause();
            stage("FAIL: " + failure);
            failure.printStackTrace(log);
            failure.printStackTrace();
        } finally { log.close(); }
    }
    private static void onMain(Runnable task) throws Exception {
        Class.forName("SDLProbeMainThread").getMethod("run", Runnable.class).invoke(null, task);
    }
    private static void testControllers(ClassLoader loader, Object sdl) throws Exception {
        Class<?> sdlType = loader.loadClass("dev.isxander.sdl.Sdl");
        Class<?> initType = loader.loadClass("dev.isxander.sdl.SdlInit");
        Class<?> gamepadType = loader.loadClass("dev.isxander.sdl.SdlGamepad");
        Class<?> idType = loader.loadClass("dev.isxander.sdl.SdlJoystickId");
        Class<?> handleType = loader.loadClass("dev.isxander.sdl.SdlGamepadHandle");
        Object init = sdlType.getMethod("init").invoke(sdl);
        Object gamepad = sdlType.getMethod("gamepad").invoke(sdl);
        int flag = initType.getField("SDL_INIT_GAMEPAD").getInt(null);
        final boolean[] initialized = {false};
        final List<Object> inputHandles = new ArrayList<Object>();
        final boolean sampleInput = SDLBindingProbe.class.getResource("/probe-input") != null;
        try {
            onMain(() -> {
                try {
                    Class.forName("SDLProbeMainThread").getMethod("ready").invoke(null);
                    stage("Initializing SDL gamepad subsystem on the UIKit main thread");
                    initialized[0] = Boolean.TRUE.equals(initType.getMethod("SDL_InitSubSystem", int.class).invoke(init, flag));
                    if (!initialized[0]) {
                        Object error = sdlType.getMethod("error").invoke(sdl);
                        throw new IOException("SDL init failed: " + loader.loadClass("dev.isxander.sdl.SdlError")
                                .getMethod("SDL_GetError").invoke(error));
                    }
                    stage("PASS: SDL gamepad subsystem initialized");
                } catch (Exception e) { throw new RuntimeException(e); }
            });
            // Let GameController's asynchronous discovery run without blocking UIKit.
            Thread.sleep(2000);
            onMain(() -> {
                try {
                    Object[] ids = (Object[])gamepadType.getMethod("SDL_GetGamepads").invoke(gamepad);
                    if (ids == null) throw new IOException("SDL_GetGamepads returned null");
                    stage("Discovered gamepads: " + ids.length);
                    for (Object id : ids) {
                        stage("Controller: " + gamepadType.getMethod("SDL_GetGamepadNameForID", idType).invoke(gamepad, id));
                        Object handle = gamepadType.getMethod("SDL_OpenGamepad", idType).invoke(gamepad, id);
                        if (handle == null || ((Long)handleType.getMethod("address").invoke(handle)).longValue() == 0)
                            throw new IOException("Could not open discovered controller");
                        if (sampleInput) inputHandles.add(handle);
                        else gamepadType.getMethod("SDL_CloseGamepad", handleType).invoke(gamepad, handle);
                        stage("PASS: controller opened through unchanged FFM backend");
                    }
                    stage("Discovery completed.");
                } catch (Exception e) { throw new RuntimeException(e); }
            });
            if (sampleInput) testInput(gamepadType, handleType, gamepad, inputHandles);
            else if (SDLBindingProbe.class.getResource("/probe-hotplug") != null)
                testHotplug(loader, sdl, gamepadType, idType, handleType, gamepad);
            else stage("Buttons, axes and rumble remain untested.");
        } finally {
            if (initialized[0]) onMain(() -> {
                try {
                    try {
                        for (Object handle : inputHandles)
                            gamepadType.getMethod("SDL_CloseGamepad", handleType).invoke(gamepad, handle);
                    } finally { initType.getMethod("SDL_QuitSubSystem", int.class).invoke(init, flag); }
                    stage("Released the probe's SDL gamepad subsystem reference");
                } catch (Exception e) { throw new RuntimeException(e); }
            });
        }
    }
    private static void testHotplug(ClassLoader loader, Object sdl, Class<?> api, Class<?> idType, Class<?> handleType, Object gamepad) throws Exception {
        Object events = loader.loadClass("dev.isxander.sdl.Sdl").getMethod("events").invoke(sdl);
        Method pump = loader.loadClass("dev.isxander.sdl.SdlEvents").getMethod("SDL_PumpEvents");
        final Map<Integer, Object> handles = new LinkedHashMap<Integer, Object>();
        final boolean[] rumbled = {false}, removed = {false}, returned = {false};
        final boolean[] initiallyPresent = {false};
        stage("HOTPLUG TEST v2: pumping SDL events; 60 seconds to disconnect and reconnect the controller");
        final long started = System.nanoTime();
        long deadline = started + 60000000000L;
        try {
            do {
                onMain(() -> {
                    try {
                        pump.invoke(events);
                        Object[] ids = (Object[])api.getMethod("SDL_GetGamepads").invoke(gamepad);
                        if (ids == null) throw new IOException("SDL_GetGamepads returned null");
                        Set<Integer> current = new HashSet<Integer>();
                        for (Object id : ids) current.add((Integer)idType.getMethod("value").invoke(id));
                        Iterator<Map.Entry<Integer, Object>> entries = handles.entrySet().iterator();
                        while (entries.hasNext()) {
                            Map.Entry<Integer, Object> entry = entries.next();
                            if (!current.contains(entry.getKey())) {
                                api.getMethod("SDL_CloseGamepad", handleType).invoke(gamepad, entry.getValue());
                                entries.remove(); removed[0] = true;
                                stage("DISCONNECTED at " + ((System.nanoTime() - started) / 1000000000L)
                                        + "s: controller id=" + entry.getKey());
                            }
                        }
                        for (Object id : ids) {
                            int value = (Integer)idType.getMethod("value").invoke(id);
                            if (handles.containsKey(value)) continue;
                            Object handle = api.getMethod("SDL_OpenGamepad", idType).invoke(gamepad, id);
                            if (handle == null || ((Long)handleType.getMethod("address").invoke(handle)).longValue() == 0)
                                throw new IOException("Could not open controller id=" + value);
                            handles.put(value, handle);initiallyPresent[0] = true;
                            if (removed[0]) returned[0] = true;
                            stage("CONNECTED at " + ((System.nanoTime() - started) / 1000000000L)
                                    + "s: id=" + value + ", name="
                                    + api.getMethod("SDL_GetGamepadName", handleType).invoke(gamepad, handle));
                            if (!rumbled[0] && SDLBindingProbe.class.getResource("/probe-no-rumble") == null) {
                                rumbled[0] = true;
                                stage("Requesting one 300 ms rumble at 25% strength; report whether you feel it");
                                Object ok = api.getMethod("SDL_RumbleGamepad", handleType, short.class, short.class, int.class)
                                        .invoke(gamepad, handle, (short)16384, (short)16384, 300);
                                stage("RUMBLE request accepted=" + ok + "; physical vibration requires user confirmation");
                            }
                        }
                    } catch (Exception e) { throw new RuntimeException(e); }
                });
                if (!initiallyPresent[0]) {
                    stage("SKIP: connect a controller before running the hotplug test");
                    return;
                }
                Thread.sleep(200);
            } while (System.nanoTime() < deadline);
            stage("HOTPLUG SUMMARY: removal observed=" + removed[0] + "; controller reopened after removal=" + returned[0]);
            stage("Reopening alone does not verify input after reconnect or identify the same physical controller.");
        } finally {
            onMain(() -> {
                try {
                    for (Object handle : handles.values())
                        api.getMethod("SDL_CloseGamepad", handleType).invoke(gamepad, handle);
                    handles.clear();
                } catch (Exception e) { throw new RuntimeException(e); }
            });
        }
    }
    private static void testInput(Class<?> api, Class<?> handleType, Object gamepad, List<Object> handles) throws Exception {
        if (handles.isEmpty()) { stage("SKIP: no controller available for input testing"); return; }
        Method update = api.getMethod("SDL_UpdateGamepads");
        Method connected = api.getMethod("SDL_GamepadConnected", handleType);
        Method getButton = api.getMethod("SDL_GetGamepadButton", handleType, int.class);
        Method getAxis = api.getMethod("SDL_GetGamepadAxis", handleType, int.class);
        final String[] buttonNames = {"south/cross", "east/circle", "west/square", "north/triangle",
                "back/share", "guide", "start/options", "left-stick", "right-stick", "L1", "R1",
                "dpad-up", "dpad-down", "dpad-left", "dpad-right"};
        final String[] axisNames = {"left-X", "left-Y", "right-X", "right-Y", "L2", "R2"};
        final boolean[][] buttons = new boolean[handles.size()][buttonNames.length];
        final boolean[][] seenButtons = new boolean[handles.size()][buttonNames.length];
        final boolean[][] seenAxes = new boolean[handles.size()][axisNames.length];
        final int[][] axes = new int[handles.size()][axisNames.length];
        stage("INPUT TEST: 20 seconds; press face buttons/D-pad/shoulders and move both sticks/triggers");
        long deadline = System.nanoTime() + 20000000000L;
        while (System.nanoTime() < deadline) {
            onMain(() -> {
                try {
                    update.invoke(gamepad);
                    for (int c = 0; c < handles.size(); c++) {
                        Object handle = handles.get(c);
                        if (!Boolean.TRUE.equals(connected.invoke(gamepad, handle)))
                            throw new IOException("Controller disconnected during input test");
                        for (int b = 0; b < buttonNames.length; b++) {
                            boolean down = Boolean.TRUE.equals(getButton.invoke(gamepad, handle, b));
                            if (down) seenButtons[c][b] = true;
                            if (buttons[c][b] != down) {
                                buttons[c][b] = down;
                                stage("Controller " + c + " button " + buttonNames[b] + (down ? " DOWN" : " UP"));
                            }
                        }
                        for (int a = 0; a < axisNames.length; a++) {
                            int value = ((Short)getAxis.invoke(gamepad, handle, a)).intValue();
                            if (Math.abs(value) >= 12000) seenAxes[c][a] = true;
                            if (Math.abs(value - axes[c][a]) >= 8000) {
                                axes[c][a] = value;
                                stage("Controller " + c + " axis " + axisNames[a] + " = " + value);
                            }
                        }
                    }
                } catch (Exception e) { throw new RuntimeException(e); }
            });
            Thread.sleep(50);
        }
        for (int c = 0; c < handles.size(); c++) {
            List<String> pressed = new ArrayList<String>(), moved = new ArrayList<String>();
            for (int b = 0; b < buttonNames.length; b++) if (seenButtons[c][b]) pressed.add(buttonNames[b]);
            for (int a = 0; a < axisNames.length; a++) if (seenAxes[c][a]) moved.add(axisNames[a]);
            stage("INPUT SUMMARY controller " + c + ": pressed=" + pressed + "; moved=" + moved);
        }
        stage("Input sampling finished. Unobserved controls and rumble remain unverified.");
    }
    private static void testCallback(ClassLoader loader, Object sdl) throws Exception {
        Class<?> api = loader.loadClass("dev.isxander.sdl.SdlProperties");
        Class<?> idType = loader.loadClass("dev.isxander.sdl.SdlPropertiesId");
        Class<?> callbackType = loader.loadClass("dev.isxander.sdl.SdlCallbacks$EnumeratePropertiesCallback");
        Class<?> pointerType = loader.loadClass("dev.isxander.sdl.SdlPointer");
        Object properties = loader.loadClass("dev.isxander.sdl.Sdl").getMethod("properties").invoke(sdl);
        Object id = api.getMethod("SDL_CreateProperties").invoke(properties);
        try {
            Object set = api.getMethod("SDL_SetStringProperty", idType, String.class, String.class)
                    .invoke(properties, id, "amethyst.probe.callback", "test");
            if (!Boolean.TRUE.equals(set)) throw new IOException("Could not create temporary SDL property");
            final int[] calls = {0};
            Object callback = java.lang.reflect.Proxy.newProxyInstance(loader, new Class<?>[]{callbackType},
                    (proxy, method, args) -> {
                        if ("hashCode".equals(method.getName())) return System.identityHashCode(proxy);
                        if ("equals".equals(method.getName())) return proxy == args[0];
                        if ("toString".equals(method.getName())) return "SDL callback probe";
                        if ("accept".equals(method.getName()) && "amethyst.probe.callback".equals(args[2])) calls[0]++;
                        return null;
                    });
            stage("Testing native-to-Java callback with a temporary in-memory SDL property");
            Object result = api.getMethod("SDL_EnumerateProperties", idType, callbackType, pointerType)
                    .invoke(properties, id, callback, pointerType.getField("NULL").get(null));
            if (!Boolean.TRUE.equals(result) || calls[0] != 1)
                throw new IOException("Callback verification failed: result=" + result + ", count=" + calls[0]);
            stage("PASS: unchanged FFM backend received the native callback");
        } finally {
            api.getMethod("SDL_DestroyProperties", idType).invoke(properties, id);
        }
    }
    static Path findSDL() throws IOException {
        String explicit = System.getProperty("amethyst.probe.sdl");
        if (explicit != null) return Paths.get(explicit).toRealPath();
        for (String directory : System.getProperty("java.library.path", "").split(File.pathSeparator)) {
            for (String relative : new String[]{"lwjgl34/libSDL3.dylib", "libSDL3.dylib"}) {
                Path path = Paths.get(directory).resolve(relative);
                if (Files.isRegularFile(path)) return path.toRealPath();
            }
        }
        throw new FileNotFoundException("Bundled SDL3 not found; use -Damethyst.probe.sdl=/absolute/path");
    }
}
