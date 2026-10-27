package org.lwjgl.opengl;

import org.lwjgl.LWJGLException;

/**
 * Amethyst iOS: emulation of LWJGL 2 shared contexts with the single real context the GL bridge has.
 *
 * <p>Loading screens such as BetterLoadingScreen (1.7.10) and Forge's splash give the display's context to a
 * render thread and keep working on the main thread through a {@link SharedDrawable}. With real shared
 * contexts both threads render at once; here there is one context, and the renderers (gl4es, MobileGlues)
 * keep global state that isn't thread-safe, so two threads calling GL at once crash.</p>
 *
 * <p>Instead, {@link SharedDrawable#makeCurrent()} lends the display's context to its caller (the
 * <i>borrower</i>, the loading thread), and any other thread that makes the display current (the
 * <i>guest</i>, the loading screen's render thread) waits. The two take turns: at a safe point of the
 * loading thread ({@link #safePoint()}, called when Forge reports loading progress) the borrower hands the
 * context to the waiting guest, which draws one frame and hands it back from {@link Display#update()}.
 * The guest's frame runs between {@link #saveGuestState()} and {@link #restoreGuestState()}, so the loading
 * thread finds the GL state as it left it. GL is never used from two threads at once.</p>
 */
public final class ContextLending {

    /** At most this often (ms) the loading thread stops to let the loading screen draw a frame (~60 fps). */
    private static final long FRAME_INTERVAL_MS = 16;

    /** Thread the display's context is lent to, or null. */
    private static Thread borrower;
    /** Thread waiting for (or drawing during) a turn while the context is lent, or null. */
    private static Thread guest;
    /** The guest is blocked waiting for a turn. */
    private static boolean guestWaiting;
    /** The guest has the context for a turn; the borrower waits until it gives it back. */
    private static boolean guestTurn;
    private static long lastTurnEnd;
    /** Cheap check for {@link #safePoint()}, which runs often: whether the context is lent at all. */
    private static volatile boolean lent;

    private ContextLending() {
    }

    static synchronized void lend(Thread thread) {
        borrower = thread;
        lent = true;
        guestTurn = false;
        lastTurnEnd = 0;
    }

    static synchronized void giveBack() {
        borrower = null;
        lent = false;
        guestTurn = false;
        ContextLending.class.notifyAll();
    }

    /**
     * Waits while the display's context is lent to another live thread, until it is given back or this
     * thread is given a turn. Fails instead of waiting forever when that thread is itself waiting for the
     * caller to finish (Thread.join), which a loading screen does if it joins its render thread before giving
     * the context back (Forge's splash does).
     *
     * @return true if the caller got a turn: it must then call {@link #saveGuestState()} once the context is
     *         current, and give the context back from {@link Display#update()}
     */
    static synchronized boolean awaitDisplayContext() throws LWJGLException {
        Thread me = Thread.currentThread();
        boolean interrupted = false;
        try {
            while (borrower != null && borrower != me) {
                if (!borrower.isAlive()) {
                    borrower = null;
                    break;
                }
                if (guest == me && guestTurn) {
                    guestWaiting = false;
                    return true;
                }
                if (isJoining(borrower)) {
                    throw new LWJGLException("The display's context is lent to " + borrower.getName()
                            + ", which is waiting for " + me.getName() + " to finish");
                }
                guest = me;
                guestWaiting = true;
                try {
                    ContextLending.class.wait(500);
                } catch (InterruptedException e) {
                    interrupted = true;
                }
            }
            if (guest == me) {
                guest = null;
                guestWaiting = false;
                guestTurn = false;
            }
            return false;
        } finally {
            if (interrupted) {
                me.interrupt();
            }
        }
    }

    /** Whether the calling thread is drawing during a turn (it has the lent context). */
    static synchronized boolean isGuestTurn() {
        return borrower != null && guestTurn && guest == Thread.currentThread();
    }

    static synchronized void endGuestTurn() {
        guestTurn = false;
        lastTurnEnd = System.currentTimeMillis();
        ContextLending.class.notifyAll();
    }

    /**
     * Called by {@link Display#update()} on the guest: gives the context back to the borrower for the rest of
     * its turn and waits for the next turn (or for the context to be given back for good).
     */
    static void guestFrameDone(DrawableGL display) throws LWJGLException {
        if (!isGuestTurn()) {
            return;
        }
        restoreGuestState();
        synchronized (GlobalLock.lock) {
            if (display.context.isCurrent()) {
                display.context.releaseCurrent();
            }
        }
        endGuestTurn();
        boolean turn = awaitDisplayContext();
        synchronized (GlobalLock.lock) {
            display.context.makeCurrent();
        }
        if (turn) {
            saveGuestState();
        }
    }

    /**
     * A point where the loading thread isn't in the middle of any GL work (Forge reporting loading progress,
     * through FMLClientHandler.processWindowMessages(), which asks {@code LWJGLUtil.getPlatform()}). If it has
     * the lent context and the loading screen is waiting, let it draw a frame.
     */
    public static void safePoint() {
        if (!lent) {
            return;
        }
        Thread me = Thread.currentThread();
        synchronized (ContextLending.class) {
            if (borrower != me || guest == null || !guestWaiting || guestTurn || !guest.isAlive()
                    || System.currentTimeMillis() - lastTurnEnd < FRAME_INTERVAL_MS) {
                return;
            }
        }
        if (!calledFromProgressReport()) {
            return;
        }
        Drawable drawable = Display.getDrawable();
        if (!(drawable instanceof DrawableGL)) {
            return;
        }
        DrawableGL display = (DrawableGL)drawable;
        try {
            synchronized (GlobalLock.lock) {
                if (display.context == null || !display.context.isCurrent()) {
                    return;
                }
                display.context.releaseCurrent();
            }
            boolean interrupted = false;
            synchronized (ContextLending.class) {
                guestTurn = true;
                ContextLending.class.notifyAll();
                while (guestTurn && borrower == me && guest != null && guest.isAlive()) {
                    try {
                        ContextLending.class.wait(1000);
                    } catch (InterruptedException e) {
                        interrupted = true;
                    }
                }
                guestTurn = false;
                lastTurnEnd = System.currentTimeMillis();
            }
            synchronized (GlobalLock.lock) {
                display.context.makeCurrent();
            }
            if (interrupted) {
                me.interrupt();
            }
        } catch (LWJGLException | RuntimeException e) {
            System.err.println("[ContextLending] Could not let the loading screen draw: " + e);
        }
    }

    private static boolean calledFromProgressReport() {
        for (StackTraceElement frame : new Throwable().getStackTrace()) {
            if ("processWindowMessages".equals(frame.getMethodName())) {
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------------
    // GL state around the guest's frames

    private static final int MATRIX_MODES[] = {GL11.GL_MODELVIEW, GL11.GL_PROJECTION, GL11.GL_TEXTURE};
    private static final int TEXTURE_UNITS = 4;

    private static boolean saved;
    private static int savedActiveTexture, savedMatrixMode, savedProgram, savedArrayBuffer, savedElementBuffer,
            savedFramebuffer;
    private static final int[] savedTextures = new int[TEXTURE_UNITS];

    /** Saves the borrower's GL state and gives the guest a clean one, once the guest has the context. */
    static void saveGuestState() {
        try {
            GLCapabilities caps = GL.getCapabilities();
            boolean multitexture = caps.glActiveTexture != 0;
            savedActiveTexture = multitexture ? GL11.glGetInteger(GL13.GL_ACTIVE_TEXTURE) : GL13.GL_TEXTURE0;
            for (int i = 0; i < (multitexture ? TEXTURE_UNITS : 1); i++) {
                if (multitexture) GL13.glActiveTexture(GL13.GL_TEXTURE0 + i);
                savedTextures[i] = GL11.glGetInteger(GL11.GL_TEXTURE_BINDING_2D);
            }
            if (multitexture) GL13.glActiveTexture(GL13.GL_TEXTURE0);
            savedMatrixMode = GL11.glGetInteger(GL11.GL_MATRIX_MODE);
            savedProgram = caps.glUseProgram != 0 ? GL11.glGetInteger(GL20.GL_CURRENT_PROGRAM) : 0;
            savedArrayBuffer = caps.glBindBuffer != 0 ? GL11.glGetInteger(GL15.GL_ARRAY_BUFFER_BINDING) : 0;
            savedElementBuffer = caps.glBindBuffer != 0 ? GL11.glGetInteger(GL15.GL_ELEMENT_ARRAY_BUFFER_BINDING) : 0;
            savedFramebuffer = hasFramebuffers(caps) ? GL11.glGetInteger(GL30.GL_FRAMEBUFFER_BINDING) : 0;

            if (caps.glPushAttrib == 0 || caps.glPushClientAttrib == 0 || caps.glPushMatrix == 0) {
                return; // core-profile renderer: nothing to push the state on
            }
            GL11.glPushAttrib(GL11.GL_ALL_ATTRIB_BITS);
            GL11.glPushClientAttrib(GL11.GL_CLIENT_ALL_ATTRIB_BITS);
            for (int mode : MATRIX_MODES) {
                GL11.glMatrixMode(mode);
                GL11.glPushMatrix();
            }
            GL11.glMatrixMode(GL11.GL_MODELVIEW);

            if (savedProgram != 0) GL20.glUseProgram(0);
            if (savedArrayBuffer != 0) GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, 0);
            if (savedElementBuffer != 0) GL15.glBindBuffer(GL15.GL_ELEMENT_ARRAY_BUFFER, 0);
            if (savedFramebuffer != 0) bindFramebuffer(caps, 0);
            drainErrors();
            saved = true;
        } catch (RuntimeException e) {
            System.err.println("[ContextLending] Could not save the GL state: " + e);
        }
    }

    /** Puts back the state {@link #saveGuestState()} saved, before the guest gives the context back. */
    static void restoreGuestState() {
        if (!saved) {
            return;
        }
        saved = false;
        try {
            GLCapabilities caps = GL.getCapabilities();
            boolean multitexture = caps.glActiveTexture != 0;
            if (multitexture) GL13.glActiveTexture(GL13.GL_TEXTURE0);
            for (int mode : MATRIX_MODES) {
                GL11.glMatrixMode(mode);
                GL11.glPopMatrix();
            }
            GL11.glPopClientAttrib();
            GL11.glPopAttrib();

            if (hasFramebuffers(caps)) bindFramebuffer(caps, savedFramebuffer);
            if (caps.glBindBuffer != 0) {
                GL15.glBindBuffer(GL15.GL_ARRAY_BUFFER, savedArrayBuffer);
                GL15.glBindBuffer(GL15.GL_ELEMENT_ARRAY_BUFFER, savedElementBuffer);
            }
            if (caps.glUseProgram != 0) GL20.glUseProgram(savedProgram);
            for (int i = 0; i < (multitexture ? TEXTURE_UNITS : 1); i++) {
                if (multitexture) GL13.glActiveTexture(GL13.GL_TEXTURE0 + i);
                GL11.glBindTexture(GL11.GL_TEXTURE_2D, savedTextures[i]);
            }
            if (multitexture) GL13.glActiveTexture(savedActiveTexture);
            GL11.glMatrixMode(savedMatrixMode);
            drainErrors();
        } catch (RuntimeException e) {
            System.err.println("[ContextLending] Could not restore the GL state: " + e);
        }
    }

    private static boolean hasFramebuffers(GLCapabilities caps) {
        return caps.glBindFramebuffer != 0 || caps.glBindFramebufferEXT != 0;
    }

    private static void bindFramebuffer(GLCapabilities caps, int framebuffer) {
        if (caps.glBindFramebuffer != 0) {
            GL30.glBindFramebuffer(GL30.GL_FRAMEBUFFER, framebuffer);
        } else {
            EXTFramebufferObject.glBindFramebufferEXT(EXTFramebufferObject.GL_FRAMEBUFFER_EXT, framebuffer);
        }
    }

    /** Errors from our own queries (an enum the renderer doesn't know) mustn't show up as the game's. */
    private static void drainErrors() {
        for (int i = 0; i < 16 && GL11.glGetError() != GL11.GL_NO_ERROR; i++) {
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
