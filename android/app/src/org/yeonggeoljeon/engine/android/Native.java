// SPDX-License-Identifier: GPL-3.0-only
package org.yeonggeoljeon.engine.android;

import java.nio.ByteBuffer;

/** The Swift engine's entry points. Every call except audioPull comes from the one game thread. */
final class Native {
    static {
        System.loadLibrary("ygjni");
    }
    private Native() {}

    static native void setHome(String path);
    static native int create(String data, String saves);
    static native void tick();
    static native boolean combatLive();
    static native void tickCombat();
    static native void setActive(boolean active);
    static native int revision();
    static native String state();
    static native ByteBuffer fieldImage(int[] size);
    static native ByteBuffer image(String key, int[] size);
    static native ByteBuffer battleImage(int[] size);
    static native void perform(int scope, String id);
    static native void fieldTap(double x, double y);
    static native void fieldScroll(int dx, int dy);
    static native void cellTap(int x, int y);
    static native void command(int code);
    static native void audioPull(float[] out, int count);
    static native int audioRate();

    static final int ADVANCE = 0, SKIP = 1, AUTO = 2, SPEED = 3, MENU = 4, CLOSE_MENU = 5, UNIT_DETAIL = 6,
        SKIP_COMBAT = 7, END_COMBAT = 8, DISMISS_BANNER = 9, CLEAR_ERROR = 10;
}
