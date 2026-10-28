package net.kdt.pojavlaunch;

import java.beans.Beans;
import java.io.*;
import java.lang.reflect.Field;
import java.util.*;
import java.util.concurrent.*;

import org.lwjgl.glfw.CallbackBridge;
import org.lwjgl.glfw.GLFW;

import net.kdt.pojavlaunch.uikit.*;
import net.kdt.pojavlaunch.utils.*;
import net.kdt.pojavlaunch.value.*;

public class PojavLauncher {
    private static float currProgress, maxProgress;

    public static void main(String[] args) throws Throwable {
        // Skip calling to com.apple.eawt.Application.nativeInitializeApplicationDelegate()
        Beans.setDesignTime(true);
        try {
            // Some places use macOS-specific code, which is unavailable on iOS
            // In this case, try to get it to use Linux-specific code instead.
            Class.forName("com.apple.eawt.Application").getMethod("getApplication").invoke(null);
            Class clazz = Class.forName("com.apple.eawt.Application");
            Field field = clazz.getDeclaredField("sApplication");
            field.setAccessible(true);
            field.set(null, null);
            sun.font.FontUtilities.isLinux = true;
            System.setProperty("java.util.prefs.PreferencesFactory", "java.util.prefs.FileSystemPreferencesFactory");
        } catch (Throwable th) {
            // Not on JRE8, ignore exception
            //Tools.showError(th);
        }

        Thread.currentThread().setUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {

            public void uncaughtException(Thread t, Throwable th) {
                th.printStackTrace();
                System.exit(1);
            }
        });

        // Caciocavallo17's preloader forces AWT out of headless mode (it overwrites GraphicsEnvironment's
        // cached headless state). Versions that need headless AWT (lwjgl3ify/RetroFuturaBootstrap, which
        // refuses to start otherwise on macOS-like platforms) are launched with java.awt.headless=true,
        // so leave AWT alone for them.
        if (!Boolean.getBoolean("java.awt.headless")) {
            try {
                // Try to initialize Caciocavallo17
                Class.forName("com.github.caciocavallosilano.cacio.ctc.CTCPreloadClassLoader");
            } catch (ClassNotFoundException e) {}
        }

        if (args[0].equals("-jar")) {
            UIKit.callback_JavaGUIViewController_launchJarFile(args[1], Arrays.copyOfRange(args, 2, args.length));
        } else {
            launchMinecraft(args);
        }
    }

    public static void launchMinecraft(String[] args) throws Throwable {
        // Args for Spiral Knights
        System.setProperty("appdir", "./spiral");
        System.setProperty("resource_dir", "./spiral/rsrc");

        String sizeStr = System.getProperty("cacio.managed.screensize");
        System.setProperty("glfw.windowSize", sizeStr);

        // Turn off Forge's loading splash (1.7.10-1.12.2). It moves the GL context to its own thread while
        // mods load, which leaves mods that render during loading (e.g. LibrarianLib) without a context,
        // since shared contexts aren't available here. Forge reads it from the instance's game directory.
        if (System.getProperty("pojav.internal.keepForgeSplash") == null) {
            disableForgeSplash(new File(Tools.DIR_GAME_PROFILE, "config/splash.properties"));
        }

        System.setProperty("org.lwjgl.vulkan.libname", "libMoltenVK.dylib");

        MinecraftAccount account = MinecraftAccount.load(args[0]);
        // Forge/NeoForge set up by the launcher finish installing here, before their files are needed
        ModLoaderPostInstall.runIfPending(args[1]);
        JMinecraftVersionList.Version version = Tools.getVersionInfo(args[1]);
        System.out.println("Launching Minecraft " + version.id);
        String configPath;
        if (version.logging != null) {
            if (version.logging.client.file.id.equals("client-1.12.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.12.xml";
            } else if (version.logging.client.file.id.equals("client-1.7.xml")) {
                configPath = Tools.DIR_BUNDLE + "/log4j-rce-patch-1.7.xml";
            } else {
                configPath = Tools.DIR_GAME_NEW + "/" + version.logging.client.file.id;
            }
            System.setProperty("log4j.configurationFile", configPath);
        }

        Tools.launchMinecraft(account, version);
    }

    private static void disableForgeSplash(File splashFile) {
        try {
            splashFile.getParentFile().mkdirs();
            String content = splashFile.isFile() ? Tools.read(splashFile.getAbsolutePath()) : "";
            if (content.matches("(?s).*(^|\\n)\\s*enabled\\s*=.*")) {
                content = content.replaceAll("(?m)^(\\s*enabled\\s*=\\s*)\\S*", "$1false");
            } else {
                content = content + (content.isEmpty() || content.endsWith("\n") ? "" : "\n") + "enabled=false\n";
            }
            Tools.write(splashFile.getAbsolutePath(), content);
        } catch (IOException e) {
            System.err.println("Could not disable the Forge splash screen: " + e);
        }
    }
}
