// SPDX-License-Identifier: GPL-3.0-only
package org.yeonggeoljeon.engine.android;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.View;

/** A small line icon for a battle command, drawn on a 24-unit grid so it needs no image files. */
final class IconView extends View {
    private final String name;
    private final Paint line = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();

    IconView(Context context, String name, int color) {
        super(context);
        this.name = name;
        line.setStyle(Paint.Style.STROKE);
        line.setStrokeCap(Paint.Cap.ROUND);
        line.setStrokeJoin(Paint.Join.ROUND);
        line.setColor(color);
        fill.setStyle(Paint.Style.FILL);
        fill.setColor(color);
    }

    void tint(int color) { line.setColor(color); fill.setColor(color); invalidate(); }

    @Override protected void onDraw(Canvas c) {
        float u = Math.min(getWidth(), getHeight()) / 24f;
        float ox = (getWidth() - 24 * u) / 2f, oy = (getHeight() - 24 * u) / 2f;
        c.save();
        c.translate(ox, oy);
        c.scale(u, u);
        line.setStrokeWidth(1.9f);
        switch (name) {
            case "move": // a boot print: arrow heading up and right
                c.drawLine(5, 19, 18, 6, line);
                path.reset(); path.moveTo(10, 6); path.lineTo(18, 6); path.lineTo(18, 14);
                c.drawPath(path, line);
                break;
            case "coop":
            case "attack": // crossed swords
                c.drawLine(5, 5, 19, 19, line);
                c.drawLine(19, 5, 5, 19, line);
                c.drawLine(4, 9, 9, 4, line);
                c.drawLine(20, 9, 15, 4, line);
                break;
            case "strategies": // a four-point spark
                path.reset();
                path.moveTo(12, 3); path.quadTo(12, 12, 21, 12); path.quadTo(12, 12, 12, 21);
                path.quadTo(12, 12, 3, 12); path.quadTo(12, 12, 12, 3);
                c.drawPath(path, fill);
                break;
            case "items": // a small chest
                c.drawRect(4, 9, 20, 20, line);
                c.drawLine(4, 13, 20, 13, line);
                c.drawLine(8, 9, 8, 5, line);
                c.drawLine(8, 5, 16, 5, line);
                c.drawLine(16, 5, 16, 9, line);
                break;
            case "wait": // pause inside a ring
                c.drawCircle(12, 12, 9, line);
                c.drawLine(9.5f, 8.5f, 9.5f, 15.5f, line);
                c.drawLine(14.5f, 8.5f, 14.5f, 15.5f, line);
                break;
            case "cancel":
                c.drawLine(6, 6, 18, 18, line);
                c.drawLine(18, 6, 6, 18, line);
                break;
            case "turn": // a flag
                c.drawLine(6, 21, 6, 4, line);
                path.reset(); path.moveTo(6, 5); path.lineTo(19, 5); path.lineTo(15, 9.5f); path.lineTo(19, 14); path.lineTo(6, 14);
                c.drawPath(path, line);
                break;
            case "next": // two chevrons
                path.reset(); path.moveTo(5, 6); path.lineTo(11, 12); path.lineTo(5, 18);
                path.moveTo(12, 6); path.lineTo(18, 12); path.lineTo(12, 18);
                c.drawPath(path, line);
                break;
            case "threat": // a warning ring with a mark
                c.drawCircle(12, 12, 9, line);
                c.drawLine(12, 7, 12, 13, line);
                c.drawCircle(12, 16.5f, 0.8f, fill);
                break;
            case "destinations": // a map pin
                c.drawCircle(12, 10, 4, line);
                path.reset(); path.moveTo(6, 11); path.lineTo(12, 21); path.lineTo(18, 11);
                c.drawPath(path, line);
                break;
            default: // a dot for anything without its own icon
                c.drawCircle(12, 12, 4, fill);
        }
        c.restore();
    }
}
