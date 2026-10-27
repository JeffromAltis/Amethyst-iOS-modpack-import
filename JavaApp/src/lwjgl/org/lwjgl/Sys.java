package org.lwjgl;

import java.awt.Desktop;
import java.net.URI;
import javax.swing.JOptionPane;
import javax.swing.UIManager;

import org.lwjgl.glfw.GLFW;

/**
 * LWJGL 2's {@code org.lwjgl.Sys} on top of LWJGL 3. Replaces the copy in lwjgl-lwjglx.jar (classes compiled
 * from src/lwjgl override the bundled jars when lwjgl.jar is packaged), with the same behaviour plus the
 * LWJGL 2 methods that copy lacks, such as {@link #is64Bit()} (used by GTNHLib in GT New Horizons).
 */
public class Sys {

    private Sys() {
    }

    public static String getVersion() {
        return Version.getVersion();
    }

    public static void initialize() {
        if (!GLFW.glfwInit()) {
            throw new IllegalStateException("Unable to initialize GLFW");
        }
    }

    /** Whether the JVM is 64-bit. Always true on iOS, which only runs arm64. */
    public static boolean is64Bit() {
        String model = System.getProperty("sun.arch.data.model");
        if (model != null) {
            return model.contains("64");
        }
        String arch = System.getProperty("os.arch", "");
        return arch.contains("64");
    }

    public static long getTimerResolution() {
        return 1000L;
    }

    public static long getTime() {
        return GLFW.glfwGetTimerValue();
    }

    public static long getNanoTime() {
        return System.nanoTime();
    }

    public static boolean openURL(String url) {
        if (!Desktop.isDesktopSupported()) {
            return false;
        }
        Desktop desktop = Desktop.getDesktop();
        if (!desktop.isSupported(Desktop.Action.BROWSE)) {
            return false;
        }
        try {
            desktop.browse(new URI(url));
            return true;
        } catch (Exception e) {
            e.printStackTrace();
            return false;
        }
    }

    public static void alert(String title, String message) {
        try {
            UIManager.setLookAndFeel(UIManager.getSystemLookAndFeelClassName());
        } catch (Exception e) {
            LWJGLUtil.log("Caught exception while setting Look-and-Feel: " + e);
        }
        JOptionPane.showMessageDialog(null, message, title, JOptionPane.WARNING_MESSAGE);
    }

    public static String getClipboard() {
        return GLFW.glfwGetClipboardString(GLFW.glfwGetPrimaryMonitor());
    }
}
