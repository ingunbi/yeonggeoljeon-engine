// SPDX-License-Identifier: GPL-3.0-only
package org.yeonggeoljeon.engine.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Dialog;
import android.graphics.Bitmap;
import android.graphics.drawable.BitmapDrawable;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

public class MainActivity extends Activity implements StageView.Listener {
    /** What one game tick produced, ready to draw on the UI thread. */
    private static final class Frame {
        JSONObject state;
        Bitmap field;
        Bitmap battle;
        boolean newMap;
        final Map<String, Bitmap> images = new HashMap<>();
    }

    private HandlerThread gameThread;
    private Handler game;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private volatile boolean running;
    private int lastRevision = -1;
    private String lastStateJson = "";
    private volatile boolean forceFrame = true;
    private String lastMapKey = "";
    private Thread audioThread;

    private FrameLayout root;
    private TextView title, status, speedButton, menuButton;
    private StageView stage;
    private LinearLayout dock;
    private HorizontalScrollView dockScroll;
    private FrameLayout overlay;
    private TextView hint;
    private View loading;
    private Dialog panelDialog;
    private String panelDialogKey = "";
    private Dialog errorDialog;
    private final Map<String, Bitmap> portraitCache = new HashMap<>();
    private String lastPanelJson = "";

    @Override protected void onCreate(Bundle saved) {
        super.onCreate(saved);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().setStatusBarColor(Ui.INK);
        getWindow().setNavigationBarColor(Ui.INK);
        buildUi();
        loading.setVisibility(View.VISIBLE);
        gameThread = new HandlerThread("game");
        gameThread.start();
        game = new Handler(gameThread.getLooper());
        game.post(this::startGame);
    }

    // ---- Start up and the game loop (game thread) ----

    private void startGame() {
        File files = getFilesDir();
        File data = new File(files, "GameData");
        File marker = new File(files, "GameData.version");
        try {
            String version = String.valueOf(getPackageManager().getPackageInfo(getPackageName(), 0).lastUpdateTime);
            if (!data.isDirectory() || !marker.isFile() || !readText(marker).equals(version)) {
                deleteTree(data);
                copyAssets("GameData", data);
                writeText(marker, version);
            }
        } catch (Exception e) {
            fail("게임 자료를 풀지 못했습니다: " + e);
            return;
        }
        Native.setHome(files.getAbsolutePath());
        File saves = new File(files, "YeonggeoljeonSaves");
        if (Native.create(data.getAbsolutePath(), saves.getAbsolutePath()) == 0) {
            // The store reports its own message in the state; keep going so it shows.
        }
        ui.post(() -> loading.setVisibility(View.GONE));
        running = true;
        startAudio();
        game.post(loop);
    }

    private static final long STEP_NANOS = 33_333_000L;
    private long clock;
    private long accumulated;
    private long statsStart, statsTicks, statsCaptureNanos, statsFrames, statsLate;
    private final java.util.concurrent.atomic.AtomicBoolean framePending = new java.util.concurrent.atomic.AtomicBoolean(false);

    /**
     * The game advances one fixed step per 1/30 s of real time, however long drawing takes: slow
     * frames are caught up with extra steps (a few at most) and drawing is skipped while the screen
     * still holds the last frame, so the pace never depends on how busy a frame was.
     */
    private final Runnable loop = new Runnable() {
        @Override public void run() {
            if (!running) return;
            long now = System.nanoTime();
            if (clock == 0) clock = now;
            accumulated += now - clock;
            clock = now;
            accumulated = Math.min(accumulated, 4 * STEP_NANOS);
            int steps = 0;
            while (accumulated >= STEP_NANOS) {
                Native.tick();
                accumulated -= STEP_NANOS;
                steps++;
            }
            statsTicks += steps;
            if (steps > 1) statsLate++;
            if (steps > 0 && !framePending.get()) {
                int revision = Native.revision();
                if (revision != lastRevision) {
                    lastRevision = revision;
                    long t0 = System.nanoTime();
                    final Frame frame = capture();
                    if (frame != null) {
                        statsCaptureNanos += System.nanoTime() - t0;
                        statsFrames++;
                        framePending.set(true);
                        ui.post(() -> { render(frame); framePending.set(false); });
                    }
                }
            }
            if (statsStart == 0) statsStart = now;
            if (now - statsStart >= 2_000_000_000L) {
                double seconds = (now - statsStart) / 1e9;
                android.util.Log.d("yg-pace", String.format(java.util.Locale.US, "ticks/s=%.1f frames/s=%.1f capture=%.1fms catchup=%d",
                    statsTicks / seconds, statsFrames / seconds, statsFrames == 0 ? 0.0 : statsCaptureNanos / 1e6 / statsFrames, statsLate));
                statsStart = now; statsTicks = 0; statsCaptureNanos = 0; statsFrames = 0; statsLate = 0;
            }
            long next = STEP_NANOS - (System.nanoTime() - clock) - accumulated;
            game.postDelayed(this, Math.max(1L, next / 1_000_000L));
        }
    };

    /** Null when nothing on screen can have changed since the last frame. */
    private Frame capture() {
        Frame frame = new Frame();
        String json = Native.state();
        try {
            frame.state = new JSONObject(json);
        } catch (Exception e) {
            frame.state = new JSONObject();
        }
        int[] size = new int[2];
        String mode = frame.state.optString("mode", "title");
        if ("battle".equals(mode) && !frame.state.optBoolean("busy") && !forceFrame && json.equals(lastStateJson)) return null;
        forceFrame = false;
        lastStateJson = json;
        if ("battle".equals(mode)) {
            frame.battle = bitmapOf(Native.battleImage(size), size);
            JSONObject battle = frame.state.optJSONObject("battle");
            String key = battle == null ? "" : battle.optInt("cols") + "x" + battle.optInt("rows") + frame.state.optString("header");
            frame.newMap = !key.equals(lastMapKey);
            lastMapKey = key;
        } else {
            lastMapKey = "";
            frame.field = bitmapOf(Native.fieldImage(size), size);
        }
        collectImages(frame, frame.state.optJSONObject("prompt"));
        collectImages(frame, frame.state.optJSONObject("unit"));
        JSONObject combat = frame.state.optJSONObject("combat");
        if (combat != null) {
            collectImages(frame, combat);
            collectImages(frame, combat.optJSONObject("left"));
            collectImages(frame, combat.optJSONObject("right"));
        }
        return frame;
    }

    private void collectImages(Frame frame, JSONObject holder) {
        if (holder == null) return;
        String key;
        for (String name : new String[] {"portrait", "image"}) {
            key = holder.optString(name, "");
            if (key.isEmpty() || frame.images.containsKey(key)) continue;
            Bitmap cached = portraitCache.get(key);
            if (cached == null) {
                int[] size = new int[2];
                cached = bitmapOf(Native.image(key, size), size);
                if (cached != null) {
                    if (portraitCache.size() > 200 && !"image".equals(name)) portraitCache.clear();
                    if (!"image".equals(name)) portraitCache.put(key, cached);
                }
            }
            if (cached != null) frame.images.put(key, cached);
        }
    }

    private static Bitmap bitmapOf(ByteBuffer pixels, int[] size) {
        if (pixels == null || size[0] <= 0 || size[1] <= 0) return null;
        Bitmap bitmap = Bitmap.createBitmap(size[0], size[1], Bitmap.Config.ARGB_8888);
        pixels.rewind();
        bitmap.copyPixelsFromBuffer(pixels);
        return bitmap;
    }

    private void fail(String message) {
        ui.post(() -> {
            loading.setVisibility(View.GONE);
            new AlertDialog.Builder(this).setMessage(message).setPositiveButton("확인", null).show();
        });
    }

    private void copyAssets(String from, File to) throws Exception {
        String[] names = getAssets().list(from);
        if (names == null || names.length == 0) {
            to.getParentFile().mkdirs();
            try (InputStream in = getAssets().open(from); OutputStream out = new FileOutputStream(to)) {
                byte[] buffer = new byte[65536];
                int n;
                while ((n = in.read(buffer)) > 0) out.write(buffer, 0, n);
            }
            return;
        }
        to.mkdirs();
        for (String name : names) copyAssets(from + "/" + name, new File(to, name));
    }
    private static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        file.delete();
    }
    private static String readText(File file) throws Exception {
        try (InputStream in = new java.io.FileInputStream(file)) {
            return new String(in.readAllBytes(), java.nio.charset.StandardCharsets.UTF_8);
        }
    }
    private static void writeText(File file, String value) throws Exception {
        try (OutputStream out = new FileOutputStream(file)) { out.write(value.getBytes(java.nio.charset.StandardCharsets.UTF_8)); }
    }

    // ---- Audio ----

    private void startAudio() {
        audioThread = new Thread(() -> {
            int rate = Native.audioRate();
            int chunk = 2048;
            int minimum = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT);
            AudioTrack track = new AudioTrack.Builder()
                .setAudioFormat(new AudioFormat.Builder().setSampleRate(rate).setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setBufferSizeInBytes(Math.max(minimum, chunk * 4 * 4))
                .setTransferMode(AudioTrack.MODE_STREAM).build();
            float[] samples = new float[chunk];
            track.play();
            while (running) {
                Native.audioPull(samples, chunk);
                track.write(samples, 0, chunk, AudioTrack.WRITE_BLOCKING);
            }
            track.stop();
            track.release();
        }, "audio");
        audioThread.setPriority(Thread.MAX_PRIORITY);
        audioThread.start();
    }

    @Override protected void onResume() {
        super.onResume();
        if (game != null) game.post(() -> { if (running) Native.setActive(true); });
    }
    @Override protected void onPause() {
        super.onPause();
        if (game != null) game.post(() -> { if (running) Native.setActive(false); });
    }
    @Override protected void onDestroy() {
        running = false;
        super.onDestroy();
    }

    // ---- Input (UI thread -> game thread) ----

    private void call(Runnable r) { if (game != null && running) game.post(() -> { r.run(); lastRevision = -1; forceFrame = true; }); }
    private void command(int code) { call(() -> Native.command(code)); }
    private void perform(int scope, String id) { call(() -> Native.perform(scope, id)); }
    @Override public void onFieldTap(double x, double y) { call(() -> Native.fieldTap(x, y)); }
    @Override public void onFieldScroll(int dx, int dy) { call(() -> Native.fieldScroll(dx, dy)); }
    @Override public void onCellTap(int x, int y) { call(() -> Native.cellTap(x, y)); }

    // ---- Screen ----

    private void buildUi() {
        root = new FrameLayout(this);
        root.setBackgroundColor(Ui.INK);
        // The window draws edge to edge; keep the picture and buttons clear of the system bars.
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        root.addView(column, new FrameLayout.LayoutParams(-1, -1));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(Ui.dp(this, 16), Ui.dp(this, 6), Ui.dp(this, 12), Ui.dp(this, 6));
        LinearLayout names = new LinearLayout(this);
        names.setOrientation(LinearLayout.VERTICAL);
        title = Ui.text(this, "영걸전", 18, Ui.TEXT, true);
        title.setSingleLine();
        status = Ui.text(this, "", 13, Ui.MUTED, false);
        status.setSingleLine();
        names.addView(title);
        names.addView(status);
        header.addView(names, new LinearLayout.LayoutParams(0, -2, 1f));
        speedButton = Ui.text(this, "1×", 17, Ui.GOLD, true);
        speedButton.setGravity(Gravity.CENTER);
        speedButton.setMinWidth(Ui.dp(this, 52));
        speedButton.setMinHeight(Ui.dp(this, 48));
        speedButton.setBackground(Ui.round(this, Ui.GLASS, 24, 0));
        speedButton.setOnClickListener(v -> command(Native.SPEED));
        header.addView(speedButton, Ui.lp(-2, Ui.dp(this, 48)));
        TextView menu = Ui.text(this, "≡", 26, Ui.GOLD, true);
        menuButton = menu;
        menu.setGravity(Gravity.CENTER);
        menu.setBackground(Ui.round(this, Ui.GLASS, 24, 0));
        menu.setOnClickListener(v -> command(Native.MENU));
        menu.setContentDescription("메뉴");
        LinearLayout.LayoutParams menuParams = Ui.lp(Ui.dp(this, 48), Ui.dp(this, 48));
        menuParams.leftMargin = Ui.dp(this, 8);
        header.addView(menu, menuParams);
        column.addView(header);

        stage = new StageView(this);
        stage.setListener(this);
        // Cards, dialogue and banners sit over the picture only, never over the header or buttons.
        FrameLayout stageHolder = new FrameLayout(this);
        stageHolder.addView(stage, new FrameLayout.LayoutParams(-1, -1));
        overlay = new FrameLayout(this);
        overlay.setClickable(false);
        stageHolder.addView(overlay, new FrameLayout.LayoutParams(-1, -1));
        column.addView(stageHolder, new LinearLayout.LayoutParams(-1, 0, 1f));

        hint = Ui.text(this, "두 손가락으로 확대 · 드래그로 지도 이동", 12, Ui.MUTED, false);
        hint.setGravity(Gravity.CENTER);
        hint.setPadding(0, Ui.dp(this, 4), 0, Ui.dp(this, 4));
        column.addView(hint);

        dockScroll = new HorizontalScrollView(this);
        dockScroll.setHorizontalScrollBarEnabled(false);
        dock = new LinearLayout(this);
        dock.setOrientation(LinearLayout.HORIZONTAL);
        dock.setGravity(Gravity.CENTER);
        dock.setPadding(Ui.dp(this, 12), Ui.dp(this, 10), Ui.dp(this, 12), Ui.dp(this, 10));
        dockScroll.setFillViewport(true);
        dockScroll.addView(dock, new FrameLayout.LayoutParams(-1, -2));
        column.addView(dockScroll);

        FrameLayout wait = new FrameLayout(this);
        wait.setBackgroundColor(Ui.INK);
        wait.setClickable(true);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER);
        box.addView(new ProgressBar(this));
        TextView message = Ui.text(this, "게임 자료를 준비하는 중입니다. 처음 한 번만 걸립니다.", 15, Ui.MUTED, false);
        message.setGravity(Gravity.CENTER);
        message.setPadding(0, Ui.dp(this, 16), 0, 0);
        box.addView(message);
        wait.addView(box, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        loading = wait;
        root.addView(wait, new FrameLayout.LayoutParams(-1, -1));
        setContentView(root);
    }

    private void render(Frame frame) {
        JSONObject s = frame.state;
        boolean started = s.optBoolean("started");
        String mode = s.optString("mode", "title");
        boolean battle = "battle".equals(mode);
        title.setText(s.optString("header", "영걸전"));
        status.setText(s.optString("status", ""));
        status.setVisibility(status.getText().length() == 0 ? View.GONE : View.VISIBLE);
        speedButton.setText(s.optInt("speed", 1) + "×");
        boolean fast = s.optInt("speed", 1) > 1;
        speedButton.setTextColor(fast ? Ui.ON_GOLD : Ui.GOLD);
        speedButton.setBackground(Ui.round(this, fast ? Ui.GOLD : Ui.GLASS, 24, 0));
        speedButton.setVisibility(started ? View.VISIBLE : View.GONE);
        menuButton.setVisibility(started ? View.VISIBLE : View.GONE);
        JSONObject prompt = s.optJSONObject("prompt"), menu = s.optJSONObject("menu"), combat = s.optJSONObject("combat");
        boolean blocked = prompt != null || (menu != null && started) || combat != null;

        if (battle) stage.show(frame.battle, true, !blocked, frame.newMap);
        else stage.show(frame.field, false, !blocked && s.optBoolean("fieldIsMap"), false);
        hint.setVisibility(battle && prompt == null ? View.VISIBLE : View.GONE);

        // Dock
        dock.removeAllViews();
        JSONArray actions = s.optJSONArray("actions");
        dockScroll.setVisibility(started && actions != null && actions.length() > 0 ? View.VISIBLE : View.GONE);
        if (started && actions != null) {
            for (int i = 0; i < actions.length(); i++) {
                JSONObject a = actions.optJSONObject(i);
                TextView b = Ui.text(this, a.optString("title"), 15, Ui.GOLD, true);
                b.setGravity(Gravity.CENTER);
                b.setSingleLine();
                b.setBackground(Ui.round(this, Ui.GLASS, 14, 0));
                b.setAlpha(a.optBoolean("enabled", true) && !blocked ? 1f : 0.35f);
                final String id = a.optString("id");
                if (a.optBoolean("enabled", true) && !blocked) b.setOnClickListener(v -> perform(2, id));
                boolean wide = actions.length() <= 3;
                LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(wide ? Ui.dp(this, 150) : 0, Ui.dp(this, 60), wide ? 0f : 1f);
                p.leftMargin = p.rightMargin = Ui.dp(this, 4);
                dock.addView(b, p);
            }
        }

        renderOverlay(frame, s, started, prompt, menu, combat);
    }

    private void renderOverlay(Frame frame, JSONObject s, boolean started, JSONObject prompt, JSONObject menu, JSONObject combat) {
        overlay.removeAllViews();
        boolean dialogue = prompt != null && prompt.optBoolean("dialogue");
        JSONObject unit = s.optJSONObject("unit");
        JSONObject banner = s.optJSONObject("banner");

        if (unit != null && prompt == null && combat == null) overlay.addView(unitCard(frame, unit), cardParams(Gravity.TOP | Gravity.START, 10));
        if (banner != null && prompt == null && combat == null) {
            TextView b = Ui.text(this, banner.optString("text") + (banner.optBoolean("waits") ? "\n눌러서 계속" : ""), 17, Ui.TEXT, true);
            b.setGravity(Gravity.CENTER);
            b.setPadding(Ui.dp(this, 22), Ui.dp(this, 14), Ui.dp(this, 22), Ui.dp(this, 14));
            b.setBackground(Ui.round(this, 0xF00E1320, 16, 0x80F5C96B));
            b.setOnClickListener(v -> command(Native.DISMISS_BANNER));
            overlay.addView(b, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        }
        if (combat != null) overlay.addView(combatView(frame, combat), new FrameLayout.LayoutParams(-1, -1));
        if (dialogue) {
            View tap = new View(this);
            tap.setOnClickListener(v -> command(Native.ADVANCE));
            overlay.addView(tap, new FrameLayout.LayoutParams(-1, -1));
            FrameLayout.LayoutParams p = new FrameLayout.LayoutParams(-1, -2, Gravity.BOTTOM);
            p.setMargins(Ui.dp(this, 12), 0, Ui.dp(this, 12), Ui.dp(this, 12));
            overlay.addView(dialogueCard(frame, s, prompt), p);
        }
        boolean titleCard = !started && menu != null && prompt == null && hasAction(menu, "new");
        if (titleCard) overlay.addView(titleMenu(menu), new FrameLayout.LayoutParams(Ui.dp(this, 380), -2, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL));
        overlay.setClickable(dialogue);

        // Prompt and menu panels live in dialogs.
        JSONObject panel = null;
        boolean isMenu = false;
        if (prompt != null && !dialogue) panel = prompt;
        else if (menu != null && !titleCard && prompt == null) { panel = menu; isMenu = true; }
        showPanel(panel, isMenu);

        if (s.has("error") && errorDialog == null) {
            errorDialog = new AlertDialog.Builder(this).setTitle("진행을 확인해 주세요").setMessage(s.optString("error"))
                .setPositiveButton("확인", (d, w) -> { command(Native.CLEAR_ERROR); })
                .setOnDismissListener(d -> errorDialog = null).show();
        }
    }

    private static boolean hasAction(JSONObject panel, String id) {
        JSONArray actions = panel.optJSONArray("actions");
        for (int i = 0; actions != null && i < actions.length(); i++) if (id.equals(actions.optJSONObject(i).optString("id"))) return true;
        return false;
    }

    private FrameLayout.LayoutParams cardParams(int gravity, int margin) {
        FrameLayout.LayoutParams p = new FrameLayout.LayoutParams(-2, -2, gravity);
        p.setMargins(Ui.dp(this, margin), Ui.dp(this, margin), Ui.dp(this, margin), Ui.dp(this, margin));
        return p;
    }

    private ImageView portraitView(Bitmap bitmap, int widthDp, int heightDp) {
        ImageView image = new ImageView(this);
        BitmapDrawable drawable = new BitmapDrawable(getResources(), bitmap);
        drawable.setFilterBitmap(false);
        image.setImageDrawable(drawable);
        image.setScaleType(ImageView.ScaleType.FIT_CENTER);
        image.setLayoutParams(Ui.lp(Ui.dp(this, widthDp), Ui.dp(this, heightDp)));
        return image;
    }

    private View unitCard(Frame frame, JSONObject u) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setPadding(Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10));
        card.setBackground(Ui.round(this, 0xEB0E1320, 14, Ui.LINE));
        Bitmap portrait = frame.images.get(u.optString("portrait"));
        if (portrait != null) {
            ImageView image = portraitView(portrait, 52, 65);
            ((LinearLayout.LayoutParams) image.getLayoutParams()).rightMargin = Ui.dp(this, 10);
            card.addView(image);
        }
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        LinearLayout top = new LinearLayout(this);
        top.setGravity(Gravity.CENTER_VERTICAL);
        top.addView(Ui.text(this, u.optString("name"), 17, u.optBoolean("enemy") ? 0xFFFF8C80 : Ui.GOLD, true));
        TextView cls = Ui.text(this, "  " + u.optString("className") + " Lv." + u.optInt("level"), 12, Ui.MUTED, false);
        top.addView(cls);
        col.addView(top);
        col.addView(gauge("병력", u.optInt("troops"), u.optInt("maxTroops"), 0xFF73CC80));
        col.addView(gauge("사기", u.optInt("morale"), 100, 0xFFF2BF59));
        col.addView(gauge("MP", u.optInt("mp"), u.optInt("maxMP"), 0xFF73A6FF));
        LinearLayout foot = new LinearLayout(this);
        foot.setGravity(Gravity.CENTER_VERTICAL);
        TextView terrain = Ui.text(this, "지형 " + u.optString("terrain") + (u.optBoolean("confused") ? " · 혼란" : ""), 12, Ui.MUTED, false);
        foot.addView(terrain, new LinearLayout.LayoutParams(0, -2, 1f));
        TextView more = Ui.text(this, "상세", 13, Ui.GOLD, true);
        more.setPadding(Ui.dp(this, 14), Ui.dp(this, 6), Ui.dp(this, 14), Ui.dp(this, 6));
        more.setBackground(Ui.round(this, Ui.GLASS, 14, 0));
        more.setOnClickListener(v -> command(Native.UNIT_DETAIL));
        foot.addView(more);
        col.addView(foot);
        card.addView(col, new LinearLayout.LayoutParams(Ui.dp(this, 240), -2));
        return card;
    }

    private View gauge(String label, int value, int max, int color) {
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        TextView name = Ui.text(this, label, 11, Ui.MUTED, false);
        row.addView(name, Ui.lp(Ui.dp(this, 30), -2));
        ProgressBar bar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        bar.setMax(Math.max(1, max));
        bar.setProgress(Math.max(0, Math.min(value, Math.max(1, max))));
        bar.getProgressDrawable().setColorFilter(color, android.graphics.PorterDuff.Mode.SRC_IN);
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(0, Ui.dp(this, 8), 1f);
        row.addView(bar, bp);
        TextView number = Ui.text(this, String.valueOf(value), 11, Ui.TEXT, false);
        number.setGravity(Gravity.END);
        row.addView(number, Ui.lp(Ui.dp(this, 40), -2));
        return row;
    }

    private View dialogueCard(Frame frame, JSONObject s, JSONObject prompt) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setPadding(Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 16), Ui.dp(this, 12));
        card.setBackground(Ui.round(this, 0xF00E1320, 18, Ui.LINE));
        card.setOnClickListener(v -> command(Native.ADVANCE));
        Bitmap portrait = frame.images.get(prompt.optString("portrait"));
        if (portrait != null) {
            ImageView image = portraitView(portrait, 84, 105);
            ((LinearLayout.LayoutParams) image.getLayoutParams()).rightMargin = Ui.dp(this, 14);
            card.addView(image);
        }
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        if (prompt.optString("title").length() > 0) col.addView(Ui.text(this, prompt.optString("title"), 17, Ui.GOLD, true));
        TextView body = Ui.text(this, prompt.optString("body"), 19, Ui.TEXT, false);
        body.setLineSpacing(Ui.dp(this, 4), 1f);
        col.addView(body);
        LinearLayout row = new LinearLayout(this);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, Ui.dp(this, 8), 0, 0);
        row.addView(toggle("자동", s.optBoolean("auto"), Native.AUTO));
        View gap = new View(this);
        row.addView(gap, Ui.lp(Ui.dp(this, 8), 1));
        row.addView(toggle("건너뛰기", s.optBoolean("skipping"), Native.SKIP));
        View spacer = new View(this);
        row.addView(spacer, new LinearLayout.LayoutParams(0, 1, 1f));
        row.addView(Ui.text(this, "눌러서 다음 ▾", 12, Ui.MUTED, false));
        col.addView(row);
        card.addView(col, new LinearLayout.LayoutParams(0, -2, 1f));
        return card;
    }

    private TextView toggle(String label, boolean on, int code) {
        TextView t = Ui.text(this, label, 14, on ? Ui.ON_GOLD : Ui.GOLD, true);
        t.setGravity(Gravity.CENTER);
        t.setMinHeight(Ui.dp(this, 40));
        t.setPadding(Ui.dp(this, 14), 0, Ui.dp(this, 14), 0);
        t.setBackground(Ui.round(this, on ? Ui.GOLD : Ui.GLASS, 20, 0));
        t.setOnClickListener(v -> command(code));
        return t;
    }

    private View titleMenu(JSONObject menu) {
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(Ui.dp(this, 18), Ui.dp(this, 18), Ui.dp(this, 18), Ui.dp(this, 18));
        box.setBackground(Ui.round(this, 0xE00E1320, 24, Ui.LINE));
        JSONArray actions = menu.optJSONArray("actions");
        for (int i = 0; actions != null && i < actions.length(); i++) {
            JSONObject a = actions.optJSONObject(i);
            String label = a.optString("title");
            TextView b = Ui.pill(this, label, "new".equals(a.optString("id")), a.optBoolean("enabled", true));
            final String id = a.optString("id");
            b.setOnClickListener(v -> perform(1, id));
            LinearLayout.LayoutParams p = Ui.lp(-1, -2);
            p.bottomMargin = Ui.dp(this, 10);
            box.addView(b, p);
        }
        return box;
    }

    private View combatView(Frame frame, JSONObject c) {
        FrameLayout wrap = new FrameLayout(this);
        wrap.setBackgroundColor(0xFF000000);
        wrap.setClickable(true);
        wrap.setOnClickListener(v -> command(Native.SKIP_COMBAT));
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.setGravity(Gravity.CENTER_VERTICAL);
        col.setPadding(Ui.dp(this, 14), Ui.dp(this, 14), Ui.dp(this, 14), Ui.dp(this, 14));
        Bitmap picture = frame.images.get(c.optString("image"));
        FrameLayout shot = new FrameLayout(this);
        if (picture != null) {
            ImageView image = new ImageView(this);
            BitmapDrawable drawable = new BitmapDrawable(getResources(), picture);
            drawable.setFilterBitmap(false);
            image.setImageDrawable(drawable);
            image.setAdjustViewBounds(true);
            image.setScaleType(ImageView.ScaleType.FIT_CENTER);
            shot.addView(image, new FrameLayout.LayoutParams(-1, -2));
        }
        if (c.has("notice")) {
            TextView n = Ui.text(this, c.optString("notice"), 15, Ui.TEXT, true);
            n.setPadding(Ui.dp(this, 14), Ui.dp(this, 8), Ui.dp(this, 14), Ui.dp(this, 8));
            n.setBackground(Ui.round(this, 0xEB0E1320, 20, 0));
            shot.addView(n, new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));
        }
        col.addView(shot, new LinearLayout.LayoutParams(-1, -2));
        LinearLayout sides = new LinearLayout(this);
        sides.setOrientation(LinearLayout.HORIZONTAL);
        sides.setPadding(0, Ui.dp(this, 10), 0, 0);
        sides.addView(combatSide(frame, c.optJSONObject("left")), new LinearLayout.LayoutParams(0, -2, 1f));
        View gap = new View(this);
        sides.addView(gap, Ui.lp(Ui.dp(this, 10), 1));
        sides.addView(combatSide(frame, c.optJSONObject("right")), new LinearLayout.LayoutParams(0, -2, 1f));
        col.addView(sides);
        JSONArray lines = c.optJSONArray("lines"), gauges = c.optJSONArray("gauges");
        if ((lines != null && lines.length() > 0) || (gauges != null && gauges.length() > 0)) {
            LinearLayout page = new LinearLayout(this);
            page.setOrientation(LinearLayout.VERTICAL);
            page.setPadding(Ui.dp(this, 14), Ui.dp(this, 14), Ui.dp(this, 14), Ui.dp(this, 14));
            page.setBackground(Ui.round(this, 0xEB0E1320, 14, Ui.LINE));
            for (int i = 0; lines != null && i < lines.length(); i++) page.addView(Ui.text(this, lines.optString(i), 18, Ui.TEXT, false));
            for (int i = 0; gauges != null && i < gauges.length(); i++) {
                JSONArray g = gauges.optJSONArray(i);
                page.addView(gauge("", g.optInt(0), g.optInt(1), Ui.GOLD));
            }
            LinearLayout.LayoutParams pp = Ui.lp(-1, -2);
            pp.topMargin = Ui.dp(this, 10);
            col.addView(page, pp);
        }
        wrap.addView(col, new FrameLayout.LayoutParams(-1, -1));
        TextView skip = Ui.text(this, "건너뛰기 ▸▸", 14, Ui.ON_GOLD, true);
        skip.setPadding(Ui.dp(this, 14), Ui.dp(this, 8), Ui.dp(this, 14), Ui.dp(this, 8));
        skip.setBackground(Ui.round(this, Ui.GOLD, 20, 0));
        skip.setOnClickListener(v -> command(Native.END_COMBAT));
        wrap.addView(skip, cardParams(Gravity.TOP | Gravity.END, 12));
        return wrap;
    }

    private View combatSide(Frame frame, JSONObject side) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setPadding(Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10), Ui.dp(this, 10));
        card.setBackground(Ui.round(this, 0xEB0E1320, 14, Ui.LINE));
        if (side == null) return card;
        Bitmap portrait = frame.images.get(side.optString("portrait"));
        if (portrait != null) {
            ImageView image = portraitView(portrait, 48, 60);
            ((LinearLayout.LayoutParams) image.getLayoutParams()).rightMargin = Ui.dp(this, 8);
            card.addView(image);
        }
        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);
        col.addView(Ui.text(this, side.optString("name"), 16, Ui.GOLD, true));
        col.addView(Ui.text(this, side.optString("classLevel"), 12, Ui.MUTED, false));
        col.addView(statRow(side.optString("valueLabel"), String.valueOf(side.optInt("value"))));
        col.addView(statRow("병력", side.optInt("troops") + "/" + side.optInt("maximum")));
        col.addView(statRow("사기", String.valueOf(side.optInt("morale"))));
        if (side.optString("extraLabel").length() > 0) col.addView(statRow(side.optString("extraLabel"), side.optString("extraText")));
        card.addView(col, new LinearLayout.LayoutParams(0, -2, 1f));
        return card;
    }

    private View statRow(String label, String value) {
        LinearLayout row = new LinearLayout(this);
        row.addView(Ui.text(this, label, 12, Ui.MUTED, false), new LinearLayout.LayoutParams(0, -2, 1f));
        row.addView(Ui.text(this, value, 13, Ui.TEXT, false));
        return row;
    }

    // ---- Panels: prompts and menus ----

    private void showPanel(JSONObject panel, boolean isMenu) {
        if (panel == null) {
            if (panelDialog != null) { Dialog d = panelDialog; panelDialog = null; panelDialogKey = ""; d.setOnDismissListener(null); d.dismiss(); }
            return;
        }
        String key = (isMenu ? "m" : "p") + panel.toString();
        if (panelDialog != null && panelDialogKey.equals(key)) return;
        if (panelDialog != null) { Dialog d = panelDialog; d.setOnDismissListener(null); d.dismiss(); }
        final boolean menu = isMenu;
        Dialog dialog = new Dialog(this);
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE);
        dialog.setContentView(panelBody(panel, menu));
        Window window = dialog.getWindow();
        window.setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(0));
        window.setLayout(Math.min(getResources().getDisplayMetrics().widthPixels - Ui.dp(this, 24), Ui.dp(this, 620)), ViewGroup.LayoutParams.WRAP_CONTENT);
        window.setGravity(menu ? Gravity.BOTTOM : Gravity.CENTER);
        window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
        window.setDimAmount(0.55f);
        dialog.setCancelable(menu);
        dialog.setCanceledOnTouchOutside(false);
        dialog.setOnDismissListener(d -> { if (menu && panelDialog == dialog) { panelDialog = null; panelDialogKey = ""; command(Native.CLOSE_MENU); } });
        panelDialog = dialog;
        panelDialogKey = key;
        dialog.show();
    }

    private View panelBody(JSONObject panel, boolean menu) {
        int scope = menu ? 1 : 0;
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(Ui.dp(this, 20), Ui.dp(this, 18), Ui.dp(this, 20), Ui.dp(this, 20));
        box.setBackground(Ui.round(this, Ui.SURFACE, 24, Ui.LINE));
        if (menu) {
            TextView close = Ui.text(this, "닫기", 16, Ui.GOLD, true);
            close.setGravity(Gravity.END);
            close.setPadding(0, 0, 0, Ui.dp(this, 6));
            close.setOnClickListener(v -> command(Native.CLOSE_MENU));
            box.addView(close, Ui.lp(-1, -2));
        }
        box.addView(Ui.text(this, panel.optString("title"), 22, Ui.TEXT, true));
        if (panel.optString("body").length() > 0) {
            TextView body = Ui.text(this, panel.optString("body"), 16, Ui.MUTED, false);
            body.setLineSpacing(Ui.dp(this, 3), 1f);
            body.setPadding(0, Ui.dp(this, 10), 0, 0);
            box.addView(body);
        }
        JSONArray actions = panel.optJSONArray("actions");
        java.util.List<JSONObject> listed = new java.util.ArrayList<>(), footer = new java.util.ArrayList<>();
        boolean choice = actions != null && actions.length() <= 3;
        for (int i = 0; actions != null && i < actions.length(); i++) {
            JSONObject a = actions.optJSONObject(i);
            if (a.optString("subtitle").length() > 0) choice = false;
        }
        for (int i = 0; actions != null && i < actions.length(); i++) {
            JSONObject a = actions.optJSONObject(i);
            String id = a.optString("id");
            boolean foot = id.equals("back") || id.equals("deploy") || id.equals("skip") || id.equals("decline") || id.startsWith("cancel");
            (choice || foot ? footer : listed).add(a);
        }
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        if (!listed.isEmpty()) {
            LinearLayout rows = new LinearLayout(this);
            rows.setOrientation(LinearLayout.VERTICAL);
            rows.setBackground(Ui.round(this, 0x0FFFFFFF, 16, 0));
            for (int i = 0; i < listed.size(); i++) {
                if (i > 0) rows.addView(Ui.divider(this));
                rows.addView(listRow(listed.get(i), scope));
            }
            LinearLayout.LayoutParams rp = Ui.lp(-1, -2);
            rp.topMargin = Ui.dp(this, 16);
            content.addView(rows, rp);
        }
        if (!footer.isEmpty()) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            for (int i = 0; i < footer.size(); i++) {
                JSONObject a = footer.get(i);
                String id = a.optString("id");
                boolean primary = id.equals("deploy") || id.equals("confirm") || id.equals("yes") || id.equals("next") || id.equals("save") || id.equals("use")
                    || id.equals("dialogue") || id.equals("shop-next") || id.equals("retirement") || id.equals("item-next") || id.equals("new");
                TextView b = Ui.pill(this, a.optString("title"), primary, a.optBoolean("enabled", true));
                b.setOnClickListener(v -> perform(scope, id));
                LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(0, -2, 1f);
                p.leftMargin = i == 0 ? 0 : Ui.dp(this, 12);
                row.addView(b, p);
            }
            LinearLayout.LayoutParams fp = Ui.lp(-1, -2);
            fp.topMargin = Ui.dp(this, 16);
            content.addView(row, fp);
        }
        ScrollView scroll = new ScrollView(this);
        scroll.addView(content);
        int max = (int) (getResources().getDisplayMetrics().heightPixels * 0.72f);
        box.addView(new BoundedScroll(this, scroll, max), Ui.lp(-1, -2));
        return box;
    }

    private View listRow(JSONObject a, int scope) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setMinimumHeight(Ui.dp(this, 56));
        row.setPadding(Ui.dp(this, 16), Ui.dp(this, 10), Ui.dp(this, 16), Ui.dp(this, 10));
        LinearLayout names = new LinearLayout(this);
        names.setOrientation(LinearLayout.VERTICAL);
        names.addView(Ui.text(this, a.optString("title"), 17, Ui.TEXT, true));
        if (a.optString("subtitle").length() > 0) names.addView(Ui.text(this, a.optString("subtitle"), 14, Ui.MUTED, false));
        row.addView(names, new LinearLayout.LayoutParams(0, -2, 1f));
        row.addView(Ui.text(this, "›", 22, Ui.MUTED, false));
        boolean enabled = a.optBoolean("enabled", true);
        row.setAlpha(enabled ? 1f : 0.35f);
        if (enabled) {
            final String id = a.optString("id");
            row.setOnClickListener(v -> perform(scope, id));
        }
        return row;
    }

    /** A scroll view that stops growing at a height. */
    private static final class BoundedScroll extends FrameLayout {
        private final int max;
        BoundedScroll(android.content.Context c, View child, int max) {
            super(c);
            this.max = max;
            addView(child, new FrameLayout.LayoutParams(-1, -2));
        }
        @Override protected void onMeasure(int w, int h) {
            super.onMeasure(w, MeasureSpec.makeMeasureSpec(max, MeasureSpec.AT_MOST));
        }
    }
}
