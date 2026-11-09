package ca.weblite.objc;

import com.sun.jna.Pointer;

/**
 * Stand-in for an Objective-C object, see {@link Client}. Every message is ignored and answers with an empty
 * result: sendBoolean is false, so code that first asks "respondsToSelector:" stops there.
 * Mods such as Cubes Without Borders wrap the NSWindow pointer themselves (new Proxy(pointer)).
 */
public class Proxy {

    private final Pointer peer;

    public Proxy() {
        this(null);
    }

    public Proxy(Pointer peer) {
        this.peer = peer;
    }

    public Proxy(Client client, Pointer peer) {
        this(peer);
    }

    public Pointer getPeer() {
        return peer;
    }

    public Proxy sendProxy(String selector, Object... args) {
        return new Proxy();
    }

    public int sendInt(String selector, Object... args) {
        return 0;
    }

    public boolean sendBoolean(String selector, Object... args) {
        return false;
    }

    public double sendDouble(String selector, Object... args) {
        return 0;
    }

    public String sendString(String selector, Object... args) {
        return null;
    }

    public Object send(String selector, Object... args) {
        return null;
    }

    public Object sendRaw(String selector, Object... args) {
        return null;
    }

}
