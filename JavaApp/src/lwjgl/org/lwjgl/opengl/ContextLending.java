package org.lwjgl.opengl;

import org.lwjgl.LWJGLException;

/**
 * Amethyst iOS: emulation of LWJGL 2 shared contexts with the single real context the GL bridge has.
 *
 * <p>Loading screens such as BetterLoadingScreen (1.7.10) and Forge's splash give the display's context to a
 * render thread and keep working on the main thread through a {@link SharedDrawable}. With real shared
 * contexts both threads render at once; here there is one context, and the renderers (MobileGlues in
 * particular) keep global state that isn't thread-safe, so two threads calling GL at once crash.</p>
 *
 * <p>Instead, {@link SharedDrawable#makeCurrent()} lends the display's context to its caller, and any other
 * thread that makes the display current waits until it is given back. The loading screen's render thread
 * therefore only draws once loading is done, and GL is never used from two threads at once.</p>
 */
final class ContextLending {

    /** Thread the display's context is lent to, or null. */
    private static Thread borrower;

    private ContextLending() {
    }

    static synchronized void lend(Thread thread) {
        borrower = thread;
    }

    static synchronized void giveBack() {
        borrower = null;
        ContextLending.class.notifyAll();
    }

    /**
     * Waits while the display's context is lent to another live thread. Fails instead of waiting forever
     * when that thread is itself waiting for the caller to finish (Thread.join), which a loading screen does
     * if it joins its render thread before giving the context back (Forge's splash does).
     */
    static synchronized void awaitDisplayContext() throws LWJGLException {
        Thread me = Thread.currentThread();
        boolean interrupted = false;
        try {
            while (borrower != null && borrower != me) {
                if (!borrower.isAlive()) {
                    borrower = null;
                    break;
                }
                if (isJoining(borrower)) {
                    throw new LWJGLException("The display's context is lent to " + borrower.getName()
                            + ", which is waiting for " + me.getName() + " to finish");
                }
                try {
                    ContextLending.class.wait(500);
                } catch (InterruptedException e) {
                    interrupted = true;
                }
            }
        } finally {
            if (interrupted) {
                me.interrupt();
            }
        }
    }

    private static boolean isJoining(Thread thread) {
        Thread.State state = thread.getState();
        if (state != Thread.State.WAITING && state != Thread.State.TIMED_WAITING) {
            return false;
        }
        for (StackTraceElement frame : thread.getStackTrace()) {
            if ("java.lang.Thread".equals(frame.getClassName()) && "join".equals(frame.getMethodName())) {
                return true;
            }
        }
        return false;
    }
}
