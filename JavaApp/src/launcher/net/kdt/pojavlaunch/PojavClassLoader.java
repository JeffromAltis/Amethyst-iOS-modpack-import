package net.kdt.pojavlaunch;

import java.io.File;
import java.io.IOException;
import java.net.*;

/**
 * This class loader is used as system class loader
 * as a workaround to modded libraries for Java 8
 * compatibility that safety casting to URLClassLoader:
 * ((URLClassLoader) ClassLoader.getSystemClassLoader())
 */
public class PojavClassLoader extends URLClassLoader {
    /**
     * Whether addURL still mirrors new URLs into java.class.path. True while the launcher
     * puts the game libraries on the class path (loaders such as BootstrapLauncher read them
     * from there); turned off right before the game's main class runs, so jars the game adds
     * later behave like on desktop, where reflective addURL calls never touch java.class.path.
     * Mixin, for example, treats any jar whose name appears in java.class.path as being on the
     * boot class path: Forge 1.7.10 adds every mixin/tweaker mod jar here, and Mixin then stopped
     * marking them reparseable, so Forge found each of them twice ("Found a duplicate mod").
     */
    static volatile boolean mirrorToClassPathProperty = true;

    public PojavClassLoader(ClassLoader parent) {
        super(new URL[0], parent);
    }

    @Override
    public void addURL(URL url) {
        super.addURL(url);
        if (!mirrorToClassPathProperty) {
            return;
        }
        try {
            System.setProperty("java.class.path", System.getProperty("java.class.path") + ":" + new File(url.toURI()).getAbsolutePath());
        } catch (URISyntaxException e) {
            e.printStackTrace();
        }
    }

    static URL getFileURL(File file) {
        try {
            file = file.getCanonicalFile();
        } catch (IOException e) {}

        try {
            return file.toURL();
        } catch (MalformedURLException e) {
            // Should never happen since we specify the protocol...
            throw new InternalError(e);
        }
    }

    /**
     * This class loader supports dynamic additions to the class path
     * at runtime.
     *
     * @see java.lang.instrument.Instrumentation#appendToSystemClassPathSearch
     */
    protected void appendToClassPathForInstrumentation(String path) {
        assert(Thread.holdsLock(this));

        // addURL is a no-op if path already contains the URL
        super.addURL(getFileURL(new File(path)));
    }
}