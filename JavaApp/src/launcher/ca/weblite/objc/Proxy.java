package ca.weblite.objc;

/** Stand-in for an Objective-C object, see {@link Client}. Every message is ignored. */
public class Proxy {

    public Proxy sendProxy(String selector, Object... args) {
        return new Proxy();
    }

    public int sendInt(String selector, Object... args) {
        return 0;
    }

    public Object send(String selector, Object... args) {
        return null;
    }

    public Object sendRaw(String selector, Object... args) {
        return null;
    }

}
