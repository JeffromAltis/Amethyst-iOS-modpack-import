package ca.weblite.objc;

import com.sun.jna.Pointer;

/** Stand-in, see {@link Client}. There is no Objective-C runtime to look selectors or classes up in. */
public class RuntimeUtils {

    public static Pointer sel(String name) {
        return null;
    }

    public static Pointer cls(String name) {
        return null;
    }

}
