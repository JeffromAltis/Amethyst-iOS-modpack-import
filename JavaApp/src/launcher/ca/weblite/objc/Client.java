package ca.weblite.objc;

/**
 * Stand-in for the Objective-C bridge library (java-objc-bridge) that Minecraft 26.x calls on macOS
 * to adjust Apple's desktop menus. Minecraft believes it runs on macOS, but iOS has no Cocoa, so the real
 * library cannot even load there. Nothing here talks to Objective-C: every call does nothing and returns
 * an empty result. Only what the game uses is provided.
 *
 * <p>This class is found before the real library's, because the launcher's own jars come first on the classpath.</p>
 */
public class Client {

    private static final Client INSTANCE = new Client();

    public static Client getInstance() {
        return INSTANCE;
    }

    public Proxy sendProxy(String className, String selector, Object... args) {
        return new Proxy();
    }

}
