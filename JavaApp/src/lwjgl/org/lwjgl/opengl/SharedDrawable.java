/*
 * Copyright (c) 2002-2008 LWJGL Project
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met:
 *
 * * Redistributions of source code must retain the above copyright
 *   notice, this list of conditions and the following disclaimer.
 *
 * * Redistributions in binary form must reproduce the above copyright
 *   notice, this list of conditions and the following disclaimer in the
 *   documentation and/or other materials provided with the distribution.
 *
 * * Neither the name of 'LWJGL' nor the names of
 *   its contributors may be used to endorse or promote products derived
 *   from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */
package org.lwjgl.opengl;

import org.lwjgl.LWJGLException;

/**
 * @author Spasi
 */

/**
 * A Drawable implementation that shares its context with another Drawable. This is useful
 * for background loading of resources. See org.lwjgl.test.opengl.multithread.BackgroundLoad
 * for an example.
 *
 * @author Spasi
 *
 * Amethyst iOS: overrides the lwjgl-lwjglx.jar copy (same source otherwise), emulating shared contexts by
 * lending the display's context, see ContextLending.
 */
public final class SharedDrawable extends DrawableGL {

    public SharedDrawable(final Drawable drawable) throws LWJGLException {
        if (drawable != null) {
            this.context = (ContextGL)((DrawableLWJGL)drawable).createSharedContext();
        } else {
            this.context = (ContextGL)((DrawableLWJGL)Display.getDrawable()).createSharedContext();
        }
    }

    public ContextGL createSharedContext() {
        return context;
        // throw new UnsupportedOperationException();
    }

    /** Thread the display's context was lent to by {@link #makeCurrent()}, or null. */
    private Thread lentTo;

    /**
     * Amethyst iOS: there is only one real context, so instead of making this drawable's own context
     * current (that used to be a no-op), lend the display's context to the caller, if the display isn't
     * using it. Other threads that make the display current wait until {@link #releaseContext()}.
     * See ContextLending.
     */
    @Override
    public void makeCurrent() throws LWJGLException {
        Drawable display = Display.getDrawable();
        if (!(display instanceof DrawableGL)) {
            return;
        }
        DrawableGL displayGL = (DrawableGL)display;
        if (displayGL.context == null || displayGL.context.isCurrent()) {
            // The display's context is in use (by this or another thread): keep the old no-op
            return;
        }
        // Lend first, so no other thread takes the context in between
        Thread me = Thread.currentThread();
        ContextLending.lend(me);
        try {
            displayGL.makeCurrent();
        } catch (LWJGLException | RuntimeException e) {
            ContextLending.giveBack();
            throw e;
        }
        lentTo = me;
    }

    @Override
    public void releaseContext() throws LWJGLException {
        if (lentTo != null && lentTo == Thread.currentThread()) {
            lentTo = null;
            try {
                Display.getDrawable().releaseContext();
            } finally {
                ContextLending.giveBack();
            }
            return;
        }
        super.releaseContext();
    }
}
