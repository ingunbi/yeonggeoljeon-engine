// SPDX-License-Identifier: GPL-3.0-only
package org.yeonggeoljeon.engine.android;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.RectF;
import android.view.GestureDetector;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;

/** The picture area. Field pictures are shown whole and tapped by fraction; the battle map pans and zooms. */
final class StageView extends View {
    interface Listener {
        void onFieldTap(double x, double y);
        void onFieldScroll(int dx, int dy);
        void onCellTap(int x, int y);
    }

    private static final int CELL = 32;
    private final Paint paint = new Paint();
    private final Matrix matrix = new Matrix();
    private final Matrix inverse = new Matrix();
    private Bitmap bitmap;
    private boolean battle;
    private boolean touchable;
    private Listener listener;
    private float zoom = 1f, panX = 0f, panY = 0f;
    private boolean fitted;
    private float carriedX, carriedY;
    private final GestureDetector gestures;
    private final ScaleGestureDetector scaler;

    StageView(Context context) {
        super(context);
        paint.setFilterBitmap(false);
        setBackgroundColor(0xFF000000);
        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent e) { carriedX = 0; carriedY = 0; return true; }
            @Override public boolean onSingleTapUp(MotionEvent e) { tapped(e.getX(), e.getY()); return true; }
            @Override public boolean onScroll(MotionEvent a, MotionEvent b, float dx, float dy) { scrolled(dx, dy); return true; }
        });
        scaler = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScale(ScaleGestureDetector d) {
                if (!battle) return false;
                float next = Math.max(1f, Math.min(3f, zoom * d.getScaleFactor()));
                float factor = next / zoom;
                panX = d.getFocusX() - (d.getFocusX() - panX) * factor;
                panY = d.getFocusY() - (d.getFocusY() - panY) * factor;
                zoom = next;
                invalidate();
                return true;
            }
        });
    }

    void setListener(Listener value) { listener = value; }

    private Runnable transformListener;
    /** Called after every draw so views pinned to a map cell can follow pan and zoom. */
    void setOnTransform(Runnable value) { transformListener = value; }

    /** Where a battle cell is on screen right now. */
    RectF cellRect(int x, int y) {
        layoutMatrix();
        float[] p = {x * CELL, y * CELL, (x + 1) * CELL, (y + 1) * CELL};
        matrix.mapPoints(p);
        return new RectF(p[0], p[1], p[2], p[3]);
    }

    /** `battleMode` keeps the zoom and pan across redraws of the same map. */
    void show(Bitmap image, boolean battleMode, boolean canTouch, boolean newMap) {
        bitmap = image;
        battle = battleMode;
        touchable = canTouch;
        if (newMap || !battleMode) { zoom = 1f; panX = 0f; panY = 0f; fitted = false; }
        invalidate();
    }

    @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        // A resized view refits instead of keeping a stale offset, so the picture never jumps.
        if (zoom == 1f) fitted = false;
    }

    private float fitScale() {
        if (bitmap == null || getWidth() == 0 || getHeight() == 0) return 1f;
        return Math.min(getWidth() / (float) bitmap.getWidth(), getHeight() / (float) bitmap.getHeight());
    }

    private void layoutMatrix() {
        matrix.reset();
        if (bitmap == null) return;
        float fit = fitScale();
        float scale = fit * (battle ? zoom : 1f);
        float shownW = bitmap.getWidth() * scale, shownH = bitmap.getHeight() * scale;
        float baseX = (getWidth() - bitmap.getWidth() * fit) / 2f, baseY = (getHeight() - bitmap.getHeight() * fit) / 2f;
        if (battle) {
            if (!fitted) { panX = baseX; panY = baseY; fitted = true; }
            // Keep the map from leaving the view completely.
            panX = shownW <= getWidth() ? (getWidth() - shownW) / 2f : Math.max(getWidth() - shownW, Math.min(0f, panX));
            panY = shownH <= getHeight() ? (getHeight() - shownH) / 2f : Math.max(getHeight() - shownH, Math.min(0f, panY));
            matrix.postScale(scale, scale);
            matrix.postTranslate(panX, panY);
        } else {
            matrix.postScale(scale, scale);
            matrix.postTranslate(baseX, baseY);
        }
        matrix.invert(inverse);
    }

    @Override protected void onDraw(Canvas canvas) {
        if (bitmap == null) return;
        layoutMatrix();
        canvas.drawBitmap(bitmap, matrix, paint);
        if (battle && transformListener != null) transformListener.run();
    }

    @Override public boolean onTouchEvent(MotionEvent event) {
        scaler.onTouchEvent(event);
        if (!scaler.isInProgress()) gestures.onTouchEvent(event);
        return true;
    }

    private void tapped(float x, float y) {
        if (bitmap == null || listener == null || !touchable) return;
        layoutMatrix();
        float[] p = {x, y};
        inverse.mapPoints(p);
        if (p[0] < 0 || p[1] < 0 || p[0] >= bitmap.getWidth() || p[1] >= bitmap.getHeight()) return;
        if (battle) listener.onCellTap((int) (p[0] / CELL), (int) (p[1] / CELL));
        else listener.onFieldTap(p[0] / bitmap.getWidth(), p[1] / bitmap.getHeight());
    }

    private void scrolled(float dx, float dy) {
        if (bitmap == null) return;
        if (battle) {
            panX -= dx;
            panY -= dy;
            invalidate();
        } else if (touchable && listener != null) {
            // A world map scrolls a tile at a time; dragging right reveals the left.
            float tile = bitmap.getWidth() * fitScale() / 32f;
            carriedX += dx;
            carriedY += dy;
            int wholeX = (int) (carriedX / tile), wholeY = (int) (carriedY / tile);
            if (wholeX != 0 || wholeY != 0) {
                listener.onFieldScroll(wholeX, wholeY);
                carriedX -= wholeX * tile;
                carriedY -= wholeY * tile;
            }
        }
    }
}
