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
        void onCellLongPress(int x, int y);
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
    /** A tall, narrow view (a phone held upright) starts zoomed in so the map is not a thin strip between black bars. */
    private boolean fillOnFit, fillTall;
    private float focusX = -1f, focusY = -1f;
    /** The cell a freshly opened, zoomed-in map is centred on; set before the map is shown. */
    void setFocus(float x, float y) { focusX = x; focusY = y; }
    /** Only a phone held upright asks for the zoomed-in start; a tablet keeps the whole map in view. */
    void setFillTall(boolean value) { fillTall = value; }
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
            @Override public void onLongPress(MotionEvent e) { longPressed(e.getX(), e.getY()); }
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
        if (newMap || !battleMode) { zoom = 1f; panX = 0f; panY = 0f; fitted = false; fillOnFit = battleMode && fillTall; }
        invalidate();
    }

    @Override protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        // A resized view refits instead of keeping a stale offset, so the picture never jumps.
        if (zoom == 1f) fitted = false;
    }

    /** Scrolls the map just enough to bring a cell (with a one-cell margin) into view. */
    void reveal(int x, int y) {
        if (bitmap == null || !battle || getWidth() == 0) return;
        RectF r = cellRect(x, y);
        float m = r.width() * 1.5f, dx = 0f, dy = 0f;
        if (r.left < m) dx = m - r.left; else if (r.right > getWidth() - m) dx = getWidth() - m - r.right;
        if (r.top < m) dy = m - r.top; else if (r.bottom > getHeight() - m) dy = getHeight() - m - r.bottom;
        if (dx != 0f || dy != 0f) { panX += dx; panY += dy; invalidate(); }
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
            if (!fitted) {
                if (fillOnFit) {
                    // A map whose shape does not match the screen (a tall map on a wide screen) would leave wide black bars;
                    // fill the screen instead and let the player scroll the other way.
                    float cover = Math.max(getWidth() / (float) bitmap.getWidth(), getHeight() / (float) bitmap.getHeight()) / fit;
                    zoom = cover >= 1.3f ? Math.min(3f, cover) : 1f;
                    fillOnFit = false;
                    scale = fit * zoom;
                    shownW = bitmap.getWidth() * scale;
                    shownH = bitmap.getHeight() * scale;
                }
                panX = (getWidth() - shownW) / 2f;
                panY = (getHeight() - shownH) / 2f;
                // Open on our own side of the map, where the player will be acting.
                if (zoom > 1f && focusX >= 0) {
                    panX = getWidth() / 2f - (focusX * CELL + CELL / 2f) * scale;
                    panY = getHeight() / 2f - (focusY * CELL + CELL / 2f) * scale;
                }
                fitted = true;
            }
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

    /** The player's map notes: {kind, x, y, x2, y2, text, style} per entry, drawn over the picture. */
    private org.json.JSONArray notes;
    private final Paint notePaint = new Paint(Paint.ANTI_ALIAS_FLAG);
    void setNotes(org.json.JSONArray value) { notes = value; invalidate(); }

    private void drawNotes(Canvas canvas) {
        if (notes == null || notes.length() == 0) return;
        for (int i = 0; i < notes.length(); i++) {
            org.json.JSONObject n = notes.optJSONObject(i);
            if (n == null) continue;
            String style = n.optString("s"), kind = n.optString("k");
            int color = "blue".equals(style) ? 0xFF4DA3FF : "pink".equals(style) ? 0xFFFF6FA8 : 0xFFFFC857;
            RectF a = cellRect(n.optInt("x"), n.optInt("y"));
            float unit = a.width();
            notePaint.setColor(color);
            notePaint.setStrokeWidth(Math.max(3f, unit * 0.12f));
            notePaint.setStyle(Paint.Style.STROKE);
            notePaint.setPathEffect("blue".equals(style) ? new android.graphics.DashPathEffect(new float[]{unit * 0.3f, unit * 0.2f}, 0)
                : "pink".equals(style) ? new android.graphics.DashPathEffect(new float[]{unit * 0.5f, unit * 0.15f}, 0) : null);
            if ("line".equals(kind) || "arrow".equals(kind)) {
                RectF b2 = cellRect(n.optInt("x2"), n.optInt("y2"));
                float x1 = a.centerX(), y1 = a.centerY(), x2 = b2.centerX(), y2 = b2.centerY();
                canvas.drawLine(x1, y1, x2, y2, notePaint);
                if ("arrow".equals(kind)) {
                    double angle = Math.atan2(y2 - y1, x2 - x1);
                    float head = unit * 0.55f;
                    notePaint.setPathEffect(null);
                    for (int side = -1; side <= 1; side += 2) {
                        double t = angle + Math.PI + side * 0.5;
                        canvas.drawLine(x2, y2, x2 + (float) (Math.cos(t) * head), y2 + (float) (Math.sin(t) * head), notePaint);
                    }
                }
            } else {
                notePaint.setPathEffect(null);
                notePaint.setStyle(Paint.Style.FILL);
                float r = unit * 0.32f;
                canvas.drawCircle(a.centerX(), a.centerY() - unit * 0.1f, r, notePaint);
                notePaint.setColor(0xFF1B2133);
                canvas.drawCircle(a.centerX(), a.centerY() - unit * 0.1f, r * 0.4f, notePaint);
                String text = n.optString("t");
                if (!text.isEmpty()) {
                    notePaint.setTextSize(Math.max(22f, unit * 0.5f));
                    notePaint.setTextAlign(Paint.Align.CENTER);
                    float w = notePaint.measureText(text) + unit * 0.4f, top = a.top - unit * 0.55f;
                    notePaint.setColor(0xDD0E1320);
                    canvas.drawRoundRect(new RectF(a.centerX() - w / 2, top - unit * 0.55f, a.centerX() + w / 2, top + unit * 0.12f), 10f, 10f, notePaint);
                    notePaint.setColor(color);
                    canvas.drawText(text, a.centerX(), top, notePaint);
                }
            }
        }
        notePaint.setPathEffect(null);
    }

    @Override protected void onDraw(Canvas canvas) {
        if (bitmap == null) return;
        layoutMatrix();
        canvas.drawBitmap(bitmap, matrix, paint);
        if (battle) drawNotes(canvas);
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

    private void longPressed(float x, float y) {
        if (bitmap == null || listener == null || !touchable || !battle) return;
        layoutMatrix();
        float[] p = {x, y};
        inverse.mapPoints(p);
        if (p[0] < 0 || p[1] < 0 || p[0] >= bitmap.getWidth() || p[1] >= bitmap.getHeight()) return;
        listener.onCellLongPress((int) (p[0] / CELL), (int) (p[1] / CELL));
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
