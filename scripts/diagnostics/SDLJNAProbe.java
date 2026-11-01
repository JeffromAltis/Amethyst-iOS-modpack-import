import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.file.*;
import java.util.*;

/** Loading/direct-registration test for the unchanged older Controlify bindings. */
public final class SDLJNAProbe {
    private static PrintWriter log;
    private static volatile boolean finished;
    private static volatile String phase;
    private static void stage(String message) {
        phase = message;
        System.out.println("[SDL JNA probe] " + message);
        log.println(message); log.flush();
    }
    public static void main(String[] args) throws Exception {
        log = new PrintWriter(Files.newBufferedWriter(Paths.get(System.getProperty("user.home"), "sdl-jna-probe.log")));
        try {
            stage("Java " + System.getProperty("java.version"));
            Path library = SDLBindingProbe.findSDL();
            stage("Found bundled SDL3");
            List<URL> jars = new ArrayList<URL>();
            for (String name : new String[]{"jna.jar", "sdl-jna.jar"}) {
                Path temp = Files.createTempFile("amethyst-jna-probe-", ".jar");
                temp.toFile().deleteOnExit();
                try (InputStream in = SDLJNAProbe.class.getResourceAsStream("/" + name)) {
                    if (in == null) throw new IOException("Missing embedded " + name);
                    Files.copy(in, temp, StandardCopyOption.REPLACE_EXISTING);
                }
                jars.add(temp.toUri().toURL());
            }
            try (URLClassLoader loader = new URLClassLoader(jars.toArray(new URL[0]), SDLJNAProbe.class.getClassLoader())) {
                stage("Loading JNA native dispatch (installed JNA 5.17.0)");
                Class.forName("com.sun.jna.Native", true, loader);
                stage("JNA native dispatch initialized");
                stage("Loading SDL3 through the unchanged libsdl4j loader");
                Class<?> factory = loader.loadClass("dev.isxander.sdl3java.jna.SdlNativeLibraryLoader");
                factory.getMethod("loadLibSDL3FromFilePathNow", String.class).invoke(null, library.toString());
                final Thread caller = Thread.currentThread();
                finished = false;
                Thread watchdog = new Thread(() -> {
                    try { Thread.sleep(5000); } catch (InterruptedException e) { return; }
                    if (!finished) {
                        String stoppedAt = phase;
                        stage("WATCHDOG: call has not completed after five seconds; last stage=" + stoppedAt);
                        stage("WATCHDOG: Java caller state=" + caller.getState());
                        for (StackTraceElement frame : caller.getStackTrace()) stage("WATCHDOG frame: " + frame);
                    }
                }, "SDL-JNA-probe-watchdog");
                watchdog.setDaemon(true);
                watchdog.start();
                stage("Testing JNA ordinary Function.invokeInt before direct registration");
                Class<?> libraryType = loader.loadClass("com.sun.jna.NativeLibrary");
                Object nativeLibrary = libraryType.getMethod("getInstance", String.class).invoke(null, library.toString());
                Object function = libraryType.getMethod("getFunction", String.class).invoke(nativeLibrary, "SDL_GetVersion");
                Object indirect = loader.loadClass("com.sun.jna.Function").getMethod("invokeInt", Object[].class)
                        .invoke(function, new Object[]{new Object[0]});
                stage("PASS: ordinary JNA function call returned SDL version=" + indirect);
                stage("SDL3 library loaded; registering original SdlVersion native methods");
                Class<?> version = Class.forName("dev.isxander.sdl3java.api.version.SdlVersion", true, loader);
                stage("Direct registration completed; calling SDL_GetVersion");
                Object value = version.getMethod("SDL_GetVersion").invoke(null);
                stage("PASS: unchanged JNA backend returned SDL version=" + value);
                stage("Callbacks, initialization and controller input remain untested.");
            }
        } catch (Throwable failure) {
            while (failure instanceof InvocationTargetException) failure = failure.getCause();
            stage("FAIL: " + failure);
            failure.printStackTrace(log); failure.printStackTrace();
        } finally { finished = true; log.close(); }
    }
}
