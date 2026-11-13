// SPDX-License-Identifier: GPL-3.0-only
package org.yeonggeoljeon.engine.android;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Colours and small view builders shared by every screen. */
final class Ui {
    static final int INK = 0xFF0E1320, SURFACE = 0xFF1B2133, GOLD = 0xFFF5C96B, ON_GOLD = 0xFF291C08, TEXT = 0xFFF2F2F5, MUTED = 0xFFA9ADBA,
        LINE = 0x33FFFFFF, GLASS = 0x18FFFFFF;
    /** The player's text size setting (1.0, 1.25 or 1.5); every label is built at its size times this. */
    static float scale = 1f;
    private Ui() {}

    static int dp(Context c, float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, c.getResources().getDisplayMetrics()));
    }
    static GradientDrawable round(Context c, int fill, float radiusDp, int stroke) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(fill);
        d.setCornerRadius(dp(c, radiusDp));
        if (stroke != 0) d.setStroke(Math.max(1, dp(c, 1)), stroke);
        return d;
    }
    static TextView text(Context c, String value, float sp, int color, boolean bold) {
        TextView t = new TextView(c);
        t.setText(value);
        t.setTextSize(sp * scale);
        t.setTextColor(color);
        if (bold) t.setTypeface(t.getTypeface(), android.graphics.Typeface.BOLD);
        return t;
    }
    static LinearLayout.LayoutParams lp(int w, int h) {
        return new LinearLayout.LayoutParams(w, h);
    }
    /** A pill button: gold when primary, outlined otherwise. */
    static TextView pill(Context c, String label, boolean primary, boolean enabled) {
        TextView t = text(c, label, 16, primary ? ON_GOLD : GOLD, true);
        t.setGravity(Gravity.CENTER);
        t.setMinHeight(dp(c, 52));
        t.setPadding(dp(c, 14), 0, dp(c, 14), 0);
        t.setBackground(primary ? round(c, GOLD, 14, 0) : round(c, GLASS, 14, 0x66F5C96B));
        t.setAlpha(enabled ? 1f : 0.35f);
        t.setEnabled(enabled);
        t.setClickable(enabled);
        return t;
    }
    static View divider(Context c) {
        View v = new View(c);
        v.setBackgroundColor(0x1AFFFFFF);
        v.setLayoutParams(lp(LinearLayout.LayoutParams.MATCH_PARENT, 1));
        return v;
    }
}
