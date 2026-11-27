"""Real-bytecode behavioral regression suite for MobileDetailScreen primary play button &
related-seasons refresh (Codex Round-11 P2 acceptance criteria ①-④).

Compiles the real unmodified Android production classes (MobileDetailScreen, CatalogScreen,
HistoryResumeMatcher, WatchHistory, NetdiskStore, SourcePreferences, PlaybackLineRules, Cms)
and executes actual View/Button/Card/Line/Page click listeners and deferred related-seasons
background delivery in default portrait inline mode (DETAIL_TAP_MODE=0) as well as fullscreen mode.
"""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, ensure_android_jar, resolve_jdk_bin
import run_wave2_android_wire_checks as wave2

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

STUBS = dict(wave2.EXTRA_RUNTIME_STUBS)

STUBS["android/view/View.java"] = STUBS["android/view/View.java"].replace(
    "    public interface OnClickListener {\n        void onClick(View v);\n    }\n",
    """    public interface OnClickListener {
        void onClick(View v);
    }

    public interface OnLongClickListener {
        boolean onLongClick(View v);
    }

    public interface OnLayoutChangeListener {
        void onLayoutChange(View v, int l, int t, int r, int b, int ol, int ot, int or, int ob);
    }

    public interface OnTouchListener {
        boolean onTouch(View v, MotionEvent event);
    }

    private ViewGroup.LayoutParams layoutParams;
    private float elevation;
    private float rotation;
    private int minWidth;
    private int minHeight;
    private boolean clipToOutline;
    private CharSequence contentDescription;
    private OnLongClickListener longClickListener;

    public void setBackgroundColor(int color) {}
    public void setOverScrollMode(int m) {}
    public void setSelected(boolean s) {}
    public boolean requestFocus() { return true; }
    public boolean hasFocus() { return false; }
    public void setFocusableInTouchMode(boolean f) {}
    public void setDefaultFocusHighlightEnabled(boolean e) {}
    public boolean isLaidOut() { return true; }
    public boolean performHapticFeedback(int f) { return true; }
    public void setLayoutParams(ViewGroup.LayoutParams lp) { this.layoutParams = lp; }
    public ViewGroup.LayoutParams getLayoutParams() { return layoutParams; }
    public void setElevation(float e) { this.elevation = e; }
    public float getElevation() { return elevation; }
    public void setRotation(float r) { this.rotation = r; }
    public float getRotation() { return rotation; }
    public void setMinimumWidth(int w) { this.minWidth = w; }
    public void setMinimumHeight(int h) { this.minHeight = h; }
    public void setClipToOutline(boolean c) { this.clipToOutline = c; }
    public void setContentDescription(CharSequence d) { this.contentDescription = d; }
    public CharSequence getContentDescription() { return contentDescription; }
    public void setOnLongClickListener(OnLongClickListener l) { this.longClickListener = l; }
    public boolean performLongClick() {
        return longClickListener != null && longClickListener.onLongClick(this);
    }
    public void setOnTouchListener(OnTouchListener l) {}
    public void addOnLayoutChangeListener(OnLayoutChangeListener l) {}
    public void setStateListAnimator(Object a) {}
    public ViewPropertyAnimator animate() { return new ViewPropertyAnimator(this); }
    public void getWindowVisibleDisplayFrame(android.graphics.Rect r) {}
""",
)

STUBS["android/view/ViewGroup.java"] = STUBS["android/view/ViewGroup.java"].replace(
    "    public void removeView(View child) {",
    """    public static class MarginLayoutParams extends LayoutParams {
        public int leftMargin;
        public int topMargin;
        public int rightMargin;
        public int bottomMargin;
        public MarginLayoutParams(int w, int h) { super(w, h); }
        public void setMargins(int l, int t, int r, int b) {
            leftMargin = l; topMargin = t; rightMargin = r; bottomMargin = b;
        }
    }

    public void removeAllViews() {
        for (View c : children) c.parent = null;
        children.clear();
    }

    public void removeView(View child) {""",
)

STUBS["android/view/ViewTreeObserver.java"] = """package android.view;
public class ViewTreeObserver {
    public interface OnPreDrawListener { boolean onPreDraw(); }
    public interface OnScrollChangedListener { void onScrollChanged(); }
    public interface OnGlobalLayoutListener { void onGlobalLayout(); }
    public void addOnPreDrawListener(OnPreDrawListener l) {}
    public void removeOnPreDrawListener(OnPreDrawListener l) {}
    public void addOnScrollChangedListener(OnScrollChangedListener l) {}
    public void removeOnScrollChangedListener(OnScrollChangedListener l) {}
    public void addOnGlobalLayoutListener(OnGlobalLayoutListener l) {}
    public void removeOnGlobalLayoutListener(OnGlobalLayoutListener l) {}
    public boolean isAlive() { return true; }
}
"""

STUBS["android/view/ViewPropertyAnimator.java"] = """package android.view;
import android.animation.TimeInterpolator;
public class ViewPropertyAnimator {
    private final View view;
    public ViewPropertyAnimator(View v) { this.view = v; }
    public ViewPropertyAnimator scaleX(float v) { view.setScaleX(v); return this; }
    public ViewPropertyAnimator scaleY(float v) { view.setScaleY(v); return this; }
    public ViewPropertyAnimator alpha(float v) { view.setAlpha(v); return this; }
    public ViewPropertyAnimator rotation(float v) { view.setRotation(v); return this; }
    public ViewPropertyAnimator translationY(float v) { view.setTranslationY(v); return this; }
    public ViewPropertyAnimator setDuration(long d) { return this; }
    public ViewPropertyAnimator setInterpolator(TimeInterpolator i) { return this; }
    public ViewPropertyAnimator withEndAction(Runnable r) { if (r != null) r.run(); return this; }
    public void start() {}
    public void cancel() {}
}
"""

STUBS["android/view/MotionEvent.java"] = """package android.view;
public class MotionEvent {
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_CANCEL = 3;
    public int getActionMasked() { return ACTION_UP; }
    public int getAction() { return ACTION_UP; }
}
"""

STUBS["android/view/Gravity.java"] = """package android.view;
public class Gravity {
    public static final int TOP = 48;
    public static final int BOTTOM = 80;
    public static final int LEFT = 3;
    public static final int RIGHT = 5;
    public static final int CENTER_VERTICAL = 16;
    public static final int CENTER_HORIZONTAL = 1;
    public static final int CENTER = 17;
    public static final int START = 8388611;
    public static final int END = 8388613;
}
"""

STUBS["android/widget/FrameLayout.java"] = """package android.widget;
import android.content.Context;
import android.view.ViewGroup;
public class FrameLayout extends ViewGroup {
    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public int gravity;
        public LayoutParams(int w, int h) { super(w, h); }
        public LayoutParams(int w, int h, int gravity) { super(w, h); this.gravity = gravity; }
    }
    public FrameLayout(Context context) { super(context); }
}
"""

STUBS["android/widget/LinearLayout.java"] = """package android.widget;
import android.content.Context;
import android.view.ViewGroup;
public class LinearLayout extends ViewGroup {
    public static final int HORIZONTAL = 0;
    public static final int VERTICAL = 1;
    public static class LayoutParams extends ViewGroup.MarginLayoutParams {
        public float weight;
        public int gravity = -1;
        public LayoutParams(int w, int h) { super(w, h); }
        public LayoutParams(int w, int h, float weight) { super(w, h); this.weight = weight; }
    }
    public LinearLayout(Context context) { super(context); }
    public void setOrientation(int o) {}
    public void setGravity(int g) {}
    public void setBaselineAligned(boolean b) {}
}
"""

STUBS["android/widget/ScrollView.java"] = """package android.widget;
import android.content.Context;
public class ScrollView extends FrameLayout {
    public ScrollView(Context context) { super(context); }
    public void setFillViewport(boolean f) {}
    public void setVerticalScrollBarEnabled(boolean e) {}
    public void scrollTo(int x, int y) {}
    public void smoothScrollTo(int x, int y) {}
}
"""

STUBS["android/widget/HorizontalScrollView.java"] = """package android.widget;
import android.content.Context;
public class HorizontalScrollView extends FrameLayout {
    public HorizontalScrollView(Context context) { super(context); }
    public void setHorizontalScrollBarEnabled(boolean e) {}
    public void scrollTo(int x, int y) {}
    public void smoothScrollTo(int x, int y) {}
}
"""

STUBS["android/widget/TextView.java"] = """package android.widget;
import android.content.Context;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.View;
public class TextView extends View {
    private CharSequence text = "";
    private int textColor;
    private float textSize;
    public TextView(Context context) { super(context); }
    public void setText(CharSequence text) { this.text = text == null ? "" : text; }
    public CharSequence getText() { return text; }
    public void setTextSize(float size) { this.textSize = size; }
    public void setTextSize(int unit, float size) { this.textSize = size; }
    public void setTextColor(int color) { this.textColor = color; }
    public void setTypeface(Typeface tf) {}
    public void setTypeface(Typeface tf, int style) {}
    public void setGravity(int g) {}
    public void setMaxLines(int m) {}
    public void setSingleLine(boolean s) {}
    public void setEllipsize(TextUtils.TruncateAt t) {}
    public void setShadowLayer(float r, float dx, float dy, int c) {}
    public void setIncludeFontPadding(boolean b) {}
    public void setLineSpacing(float add, float mult) {}
    public void setAllCaps(boolean b) {}
    public void setMinWidth(int w) {}
    public void setMaxWidth(int w) {}
}
"""

STUBS["android/widget/Button.java"] = """package android.widget;
import android.content.Context;
public class Button extends TextView {
    public Button(Context context) { super(context); }
}
"""

STUBS["android/widget/ImageView.java"] = STUBS["android/widget/ImageView.java"].replace(
    "    public Drawable getDrawable() {",
    "    public void setImageMatrix(android.graphics.Matrix m) {}\n    public Drawable getDrawable() {",
)

STUBS["android/text/TextUtils.java"] = """package android.text;
public final class TextUtils {
    public enum TruncateAt { START, MIDDLE, END, MARQUEE }
    public static boolean isEmpty(CharSequence s) { return s == null || s.length() == 0; }
}
"""

STUBS["android/text/Spanned.java"] = """package android.text;
public interface Spanned extends CharSequence {
    int SPAN_EXCLUSIVE_EXCLUSIVE = 33;
}
"""

STUBS["android/text/Spannable.java"] = """package android.text;
public interface Spannable extends Spanned {
    void setSpan(Object what, int start, int end, int flags);
    void removeSpan(Object what);
}
"""

STUBS["android/text/SpannableStringBuilder.java"] = """package android.text;
public class SpannableStringBuilder implements Spannable {
    private final StringBuilder sb;
    public SpannableStringBuilder() { this.sb = new StringBuilder(); }
    public SpannableStringBuilder(CharSequence text) { this.sb = new StringBuilder(text == null ? "" : text); }
    public void setSpan(Object what, int start, int end, int flags) {}
    public void removeSpan(Object what) {}
    public int length() { return sb.length(); }
    public char charAt(int i) { return sb.charAt(i); }
    public CharSequence subSequence(int s, int e) { return sb.subSequence(s, e); }
    @Override public String toString() { return sb.toString(); }
}
"""

STUBS["android/text/style/ImageSpan.java"] = """package android.text.style;
import android.graphics.drawable.Drawable;
public class ImageSpan {
    public static final int ALIGN_BASELINE = 1;
    public ImageSpan(Drawable d, int verticalAlignment) {}
}
"""

STUBS["android/graphics/Typeface.java"] = """package android.graphics;
public class Typeface {
    public static final int NORMAL = 0;
    public static final int BOLD = 1;
    public static final int ITALIC = 2;
    public static final Typeface DEFAULT = new Typeface();
    public static final Typeface DEFAULT_BOLD = new Typeface();
    public static Typeface create(String family, int style) { return DEFAULT; }
    public static Typeface create(Typeface family, int style) { return DEFAULT; }
}
"""

STUBS["android/graphics/Color.java"] = """package android.graphics;
public class Color {
    public static final int WHITE = 0xFFFFFFFF;
    public static final int BLACK = 0xFF000000;
    public static final int TRANSPARENT = 0;
    public static int alpha(int c) { return (c >>> 24) & 0xFF; }
    public static int red(int c) { return (c >> 16) & 0xFF; }
    public static int green(int c) { return (c >> 8) & 0xFF; }
    public static int blue(int c) { return c & 0xFF; }
    public static int rgb(int r, int g, int b) { return 0xFF000000 | (r << 16) | (g << 8) | b; }
    public static int argb(int a, int r, int g, int b) { return (a << 24) | (r << 16) | (g << 8) | b; }
    public static void colorToHSV(int color, float[] hsv) { hsv[0]=0; hsv[1]=0; hsv[2]=0; }
    public static void RGBToHSV(int r, int g, int b, float[] hsv) { hsv[0]=0; hsv[1]=0; hsv[2]=0; }
    public static int HSVToColor(float[] hsv) { return 0xFF202020; }
}
"""

STUBS["android/graphics/Xfermode.java"] = "package android.graphics;\npublic class Xfermode {}\n"
STUBS["android/graphics/PorterDuff.java"] = """package android.graphics;
public class PorterDuff {
    public enum Mode { DST_IN, SRC_IN, SRC_OVER }
}
"""
STUBS["android/graphics/PorterDuffXfermode.java"] = """package android.graphics;
public class PorterDuffXfermode extends Xfermode {
    public PorterDuffXfermode(PorterDuff.Mode m) {}
}
"""
STUBS["android/content/res/Configuration.java"] = """package android.content.res;
public class Configuration {
    public static final int UI_MODE_NIGHT_MASK = 0x30;
    public static final int UI_MODE_NIGHT_NO = 0x10;
    public static final int UI_MODE_NIGHT_YES = 0x20;
    public int uiMode = UI_MODE_NIGHT_YES;
}
"""
STUBS["android/content/res/Resources.java"] = STUBS["android/content/res/Resources.java"].replace(
    "    public DisplayMetrics getDisplayMetrics() {",
    "    private final Configuration cfg = new Configuration();\n    public Configuration getConfiguration() { return cfg; }\n    public DisplayMetrics getDisplayMetrics() {",
)
STUBS["android/provider/Settings.java"] = """package android.provider;
import android.content.ContentResolver;
public final class Settings {
    public static final class Global {
        public static final String ANIMATOR_DURATION_SCALE = "animator_duration_scale";
        public static float getFloat(ContentResolver cr, String name, float def) { return def; }
    }
}
"""
STUBS["android/content/ContentResolver.java"] = "package android.content;\npublic class ContentResolver {}\n"
STUBS["android/content/Context.java"] = STUBS["android/content/Context.java"].replace(
    "    public Resources getResources() {",
    """    private final ContentResolver resolver = new ContentResolver();
    public ContentResolver getContentResolver() { return resolver; }
    private final java.util.Map<String, SharedPreferences> spMap = new java.util.HashMap<>();
    public SharedPreferences getSharedPreferences(String name, int mode) {
        return spMap.computeIfAbsent(name, k -> new SharedPreferences() {
            private final java.util.Map<String, Object> m = new java.util.HashMap<>();
            @Override public String getString(String key, String def) { Object v = m.get(key); return v instanceof String ? (String) v : def; }
            @Override public int getInt(String key, int def) { Object v = m.get(key); return v instanceof Integer ? (Integer) v : def; }
            @Override public long getLong(String key, long def) { Object v = m.get(key); return v instanceof Long ? (Long) v : def; }
            @Override public boolean getBoolean(String key, boolean def) { Object v = m.get(key); return v instanceof Boolean ? (Boolean) v : def; }
            @Override public boolean contains(String key) { return m.containsKey(key); }
            @Override public java.util.Map<String, ?> getAll() { return new java.util.HashMap<>(m); }
            @Override public Editor edit() {
                return new Editor() {
                    @Override public Editor putString(String key, String v) { m.put(key, v); return this; }
                    @Override public Editor putInt(String key, int v) { m.put(key, v); return this; }
                    @Override public Editor putLong(String key, long v) { m.put(key, v); return this; }
                    @Override public Editor putBoolean(String key, boolean v) { m.put(key, v); return this; }
                    @Override public Editor remove(String key) { m.remove(key); return this; }
                    @Override public Editor clear() { m.clear(); return this; }
                    @Override public void apply() {}
                    @Override public boolean commit() { return true; }
                };
            }
        });
    }
    public Resources getResources() {""",
)
STUBS["android/graphics/Paint.java"] = STUBS["android/graphics/Paint.java"].replace(
    "    public void setColor(int color) {",
    """    public enum Align { LEFT, CENTER, RIGHT }
    public void setAntiAlias(boolean b) {}
    public Xfermode setXfermode(Xfermode x) { return x; }
    public void setTextAlign(Align a) {}
    public void setColor(int color) {""",
)
STUBS["android/graphics/Path.java"] = """package android.graphics;
public class Path {
    public enum FillType { WINDING, EVEN_ODD, INVERSE_WINDING, INVERSE_EVEN_ODD }
    public void setFillType(FillType ft) {}
    public void reset() {}
    public void moveTo(float x, float y) {}
    public void lineTo(float x, float y) {}
    public void cubicTo(float x1, float y1, float x2, float y2, float x3, float y3) {}
    public void quadTo(float x1, float y1, float x2, float y2) {}
    public void close() {}
    public void addCircle(float x, float y, float r, Direction d) {}
    public void addRoundRect(RectF r, float rx, float ry, Direction d) {}
    public void addRect(float l, float t, float r, float b, Direction d) {}
    public enum Direction { CW, CCW }
}
"""
STUBS["android/graphics/drawable/GradientDrawable.java"] = """package android.graphics.drawable;
import android.graphics.Canvas;
import android.graphics.ColorFilter;
public class GradientDrawable extends Drawable {
    public enum Orientation { TOP_BOTTOM, BOTTOM_TOP, LEFT_RIGHT, RIGHT_LEFT }
    public GradientDrawable() {}
    public GradientDrawable(Orientation o, int[] colors) {}
    public void setColor(int argb) {}
    public void setCornerRadius(float r) {}
    public void setCornerRadii(float[] r) {}
    public void setStroke(int w, int c) {}
    public void setShape(int s) {}
    @Override public void draw(Canvas c) {}
    @Override public void setAlpha(int a) {}
    @Override public void setColorFilter(ColorFilter f) {}
    @Override public int getOpacity() { return -3; }
}
"""
STUBS["android/content/SharedPreferences.java"] = """package android.content;
import java.util.*;
public interface SharedPreferences {
    interface Editor {
        Editor putString(String k, String v);
        Editor putInt(String k, int v);
        Editor putLong(String k, long v);
        Editor putBoolean(String k, boolean v);
        Editor remove(String k);
        Editor clear();
        void apply();
        boolean commit();
    }
    String getString(String k, String def);
    int getInt(String k, int def);
    long getLong(String k, long def);
    boolean getBoolean(String k, boolean def);
    boolean contains(String k);
    Map<String, ?> getAll();
    Editor edit();
}
"""
STUBS["android/app/Activity.java"] = """package android.app;
import android.content.Context;
public class Activity extends Context {
    public boolean isFinishing() { return false; }
    public boolean isDestroyed() { return false; }
}
"""
STUBS["android/app/Dialog.java"] = """package android.app;
public class Dialog {
    public void show() {}
    public void dismiss() {}
    public boolean isShowing() { return false; }
}
"""
STUBS["android/util/Base64.java"] = """package android.util;
public final class Base64 {
    public static final int DEFAULT = 0;
    public static final int NO_WRAP = 2;
    public static byte[] decode(String str, int flags) { return java.util.Base64.getMimeDecoder().decode(str); }
    public static String encodeToString(byte[] input, int flags) { return java.util.Base64.getEncoder().encodeToString(input); }
}
"""
STUBS["android/net/Uri.java"] = """package android.net;
public final class Uri {
    private final String raw;
    private Uri(String raw) { this.raw = raw == null ? "" : raw; }
    public static Uri parse(String s) { return new Uri(s); }
    @Override public String toString() { return raw; }
}
"""

MOBILE_INLINE_PLAYER_OVERRIDE = r"""package com.pilipala.marcomovie;

import android.widget.FrameLayout;
import java.util.*;

/** Recording stub of MobileInlinePlayer so default portrait mode (tapMode=0) captures every startEpisode call. */
final class MobileInlinePlayer {
    static final class InlineCall {
        final Cms.Site site;
        final Cms.Video video;
        final Cms.Line line;
        final Cms.Episode ep;
        final int epNum;
        final int resumeAt;
        InlineCall(Cms.Site s, Cms.Video v, Cms.Line l, Cms.Episode e, int n, int r) {
            site = s; video = v; line = l; ep = e; epNum = n; resumeAt = r;
        }
    }

    final MainActivity a;
    final List<InlineCall> calls = new ArrayList<>();

    MobileInlinePlayer(MainActivity activity, FrameLayout slot, Runnable onClosed) {
        this.a = activity;
    }

    void detach() {}

    void startEpisode(
            Cms.Site s,
            Cms.Video v,
            Cms.Line line,
            Cms.Episode ep,
            int tmdbId,
            boolean isTv,
            int seasonNum,
            int epNum) {
        calls.add(new InlineCall(s, v, line, ep, epNum, a.resumeAt));
        a.recordPlay("inline", s, v, line, ep, epNum, a.resumeAt);
    }
}
"""

SOURCE_CONTROLLER_OVERRIDE = r"""package com.pilipala.marcomovie;

/** Deterministic offline SourceController override supplying related-season search responses. */
final class SourceController {
    static volatile String nextSearchJson = "{\"list\":[]}";

    static SourceEngine engine(MainActivity a, Cms.Site site) {
        return new SourceEngine() {
            @Override public String home() { return "{\"list\":[]}"; }
            @Override public String category(String id, int page) { return "{\"list\":[]}"; }
            @Override public String detail(String id) { return "{\"list\":[]}"; }
            @Override public String search(String query, int page) { return nextSearchJson; }
            @Override public boolean requiresExternalRuntime() { return false; }
        };
    }

    static SourceEngine engine(MainActivity a, Cms.Site site, TvSearchContext ctx) {
        return engine(a, site);
    }

    static boolean isConfigOrNetdiskSite(Cms.Site site) { return false; }
}
"""

MAIN_ACTIVITY_OVERRIDE = r"""package com.pilipala.marcomovie;

import android.app.Activity;
import android.content.SharedPreferences;
import android.graphics.drawable.GradientDrawable;
import android.os.Handler;
import android.os.Looper;
import android.view.View;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import java.util.*;
import java.util.concurrent.*;

final class MemPrefs implements SharedPreferences {
    final Map<String, Object> map = new HashMap<>();
    @Override public String getString(String k, String def) { Object v = map.get(k); return v instanceof String ? (String) v : def; }
    @Override public int getInt(String k, int def) { Object v = map.get(k); return v instanceof Integer ? (Integer) v : def; }
    @Override public long getLong(String k, long def) { Object v = map.get(k); return v instanceof Long ? (Long) v : def; }
    @Override public boolean getBoolean(String k, boolean def) { Object v = map.get(k); return v instanceof Boolean ? (Boolean) v : def; }
    @Override public boolean contains(String k) { return map.containsKey(k); }
    @Override public Map<String, ?> getAll() { return new HashMap<>(map); }
    @Override public Editor edit() {
        return new Editor() {
            @Override public Editor putString(String k, String v) { map.put(k, v); return this; }
            @Override public Editor putInt(String k, int v) { map.put(k, v); return this; }
            @Override public Editor putLong(String k, long v) { map.put(k, v); return this; }
            @Override public Editor putBoolean(String k, boolean v) { map.put(k, v); return this; }
            @Override public Editor remove(String k) { map.remove(k); return this; }
            @Override public Editor clear() { map.clear(); return this; }
            @Override public void apply() {}
            @Override public boolean commit() { return true; }
        };
    }
}

public final class MainActivity extends Activity {
    public static final class PlayCall {
        public final String mode;
        public final Cms.Site site;
        public final Cms.Video video;
        public final Cms.Line line;
        public final Cms.Episode ep;
        public final int epNum;
        public final int resumeAt;
        PlayCall(String m, Cms.Site s, Cms.Video v, Cms.Line l, Cms.Episode e, int n, int r) {
            mode = m; site = s; video = v; line = l; ep = e; epNum = n; resumeAt = r;
        }
    }

    public static final class Screen {
        final Runnable show;
        boolean home;
        boolean player;
        String focus;
        final EpisodeSelection selection = new EpisodeSelection();
        Screen(Runnable show) { this.show = show; }
    }

    public interface Done<T> { void accept(T value) throws Exception; }

    static volatile MainActivity activeActivity;
    static final int WHITE = 0xfff5f5f7, MUTED = 0xffa1a1aa, DARK = 0xff101013;
    final Handler ui = new Handler(Looper.getMainLooper());
    final ExecutorService artwork = Executors.newSingleThreadExecutor();
    final ExecutorService worker = Executors.newSingleThreadExecutor();
    final ExecutorService details = Executors.newSingleThreadExecutor();
    Cms.Config config;
    String configOrigin = "";
    boolean privateMode;
    boolean reduced = true;
    int engineEpoch;
    int generation;
    boolean suppressTransitionContentView = true;
    Screen current;
    FrameLayout root;
    ScrollView scroll;
    MobileInlinePlayer inlinePlayer;
    SharedPreferences prefs = new MemPrefs();
    SharedPreferences mobilePrefsObj = new MemPrefs();
    Cms.Line activeLine;
    Cms.Episode activeEpisode;
    int resumeAt;
    WatchHistory.Entry historyFallbackBookmark;
    boolean historyFallbackInFlight;
    String migratingHistoryOldKey;

    final List<WatchHistory.Entry> historyEntries = new ArrayList<>();
    final List<PlayCall> playCalls = new ArrayList<>();
    final List<String> toasts = new ArrayList<>();
    final List<String> notices = new ArrayList<>();
    final List<Runnable> deferredPageTasks = new ArrayList<>();
    Cms.Video readyDetailVideo;

    void setupForTest(Cms.Site site, List<WatchHistory.Entry> history, Cms.Video readyVideo, int tapMode) {
        config = new Cms.Config();
        config.sites.add(site);
        historyEntries.clear();
        historyEntries.addAll(history);
        readyDetailVideo = readyVideo;
        playCalls.clear();
        toasts.clear();
        notices.clear();
        deferredPageTasks.clear();
        Handler.clearPending();
        resumeAt = 0;
        historyFallbackBookmark = null;
        mobilePrefsObj.edit().putInt(Prefs.DETAIL_TAP_MODE, tapMode).apply();
        activeActivity = this;
    }

    void recordPlay(String mode, Cms.Site s, Cms.Video v, Cms.Line l, Cms.Episode e, int epNum, int pos) {
        playCalls.add(new PlayCall(mode, s, v, l, e, epNum, pos));
    }

    void runDeferredPageTasksAndFlushUi() {
        List<Runnable> tasks = new ArrayList<>(deferredPageTasks);
        deferredPageTasks.clear();
        for (Runnable r : tasks) r.run();
        Handler.flushPending();
    }

    boolean isTvDevice() { return false; }
    boolean isPortrait() { return true; }
    boolean isReducedTransparency() { return false; }
    boolean available(Cms.Site s) { return s != null; }
    SharedPreferences mobilePrefs() { return mobilePrefsObj; }
    List<WatchHistory.Entry> watchHistory() { return new ArrayList<>(historyEntries); }
    int dp(float v) { return Math.round(v * 3f); }
    int windowWidth() { return 1080; }
    int windowHeight() { return 2400; }
    int statusBarHeight() { return 96; }
    int navigationBarHeight() { return 72; }
    void applyMobileSystemBars(boolean a, boolean b) {}
    void clearPlaybackLoading() {}
    void cancelArtwork() {}
    void cancelPageRequests() {}
    void stopWeb() {}
    void stopMagnet() {}
    void releasePlayer() {}
    boolean redirectListing(Cms.Site s, Cms.Video v) { return false; }
    void setContentView(View v) {}
    void poster(String url, ImageView img, boolean detail) {}
    void glass(View v, float radius) {}
    void onBackPressed() {}
    void crossSearch(String q) {}
    void openSearch(String q) {}
    void refresh() {}
    void clearWatchHistory(Runnable done) { if (done != null) done.run(); }
    Future<?> submitPage(Runnable r) {
        if (r != null) deferredPageTasks.add(r);
        return CompletableFuture.completedFuture(null);
    }
    SourceEngine engine(Cms.Site s) { return SourceController.engine(this, s); }

    LinearLayout vertical() {
        LinearLayout ll = new LinearLayout(this);
        ll.setOrientation(LinearLayout.VERTICAL);
        return ll;
    }
    LinearLayout row() {
        LinearLayout ll = new LinearLayout(this);
        ll.setOrientation(LinearLayout.HORIZONTAL);
        return ll;
    }
    TextView text(String s, float sp, int color) {
        TextView tv = new TextView(this);
        tv.setText(s);
        tv.setTextSize(sp);
        tv.setTextColor(color);
        return tv;
    }
    GradientDrawable bg(int color, float radiusDp) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(color);
        gd.setCornerRadius(dp(radiusDp));
        return gd;
    }
    void gap(LinearLayout parent, int dpVal) {
        parent.addView(new View(this), new LinearLayout.LayoutParams(1, dp(dpVal)));
    }
    void open(Screen screen, boolean push) {
        this.current = screen;
        if (screen != null && screen.show != null) screen.show.run();
    }
    void detail(Cms.Site s, Cms.Video listing) {
        MobileDetailScreen.show(this, s, listing, readyDetailVideo);
    }
    void detail(Cms.Site s, Cms.Video listing, Cms.Video ready) {
        MobileDetailScreen.show(this, s, listing, ready);
    }
    void loadDetail(Cms.Site s, String id, Done<Cms.Video> done) {
        try {
            if (readyDetailVideo != null) done.accept(readyDetailVideo);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
    void resolvePlayer(Cms.Site s, Cms.Video v, Cms.Line l, Cms.Episode e) {
        int epIdx = (l != null && l.episodes != null) ? l.episodes.indexOf(e) : -1;
        recordPlay("fullscreen", s, v, l, e, Math.max(1, epIdx + 1), resumeAt);
    }
    void toast(String msg) { toasts.add(msg); }
    void notice(String msg) { notices.add(msg); }
}
"""

IMMERSIVE_POSTER_OVERRIDE = r"""package com.pilipala.marcomovie;
import android.graphics.Bitmap;
public final class ImmersivePoster {
    public static final class Ratings { public double douban; public int rtPercent; }
    static void resolveHdPortraitPoster(MainActivity a, String t, String y, String ac, String d, String p, MainActivity.Done<Bitmap> cb) {}
    static void resolveMediaRatings(MainActivity a, Cms.Video v, MainActivity.Done<Ratings> cb) {}
    static Ratings extractImmediateRatings(Cms.Video v) { return new Ratings(); }
}
"""

AI_BETA_GATE_OVERRIDE = r"""package com.pilipala.marcomovie;
import android.content.Context;
public final class AiBetaGate {
    static boolean isUnlocked(Context c) { return false; }
}
"""

MOBILE_BOTTOM_SHEET_OVERRIDE = r"""package com.pilipala.marcomovie;

import android.app.Dialog;
import android.view.View;
import android.widget.TextView;

/** Capturing MobileBottomSheet override for real-bytecode line picker & PlaybackLineRules manage sheet tests. */
final class MobileBottomSheet {
    static final class SheetHandle {
        final Dialog dialog = new Dialog();
        void dismiss() { dialog.dismiss(); }
        void updateSubtitle(String s) {}
    }

    static View lastContent;
    static String[] lastPickerOptions;
    static PlayerBubble.IntAction lastPickerCallback;
    static Runnable lastConfirmCallback;

    static void resetForTest() {
        lastContent = null;
        lastPickerOptions = null;
        lastPickerCallback = null;
        lastConfirmCallback = null;
    }

    static void pickOptionContaining(String needle) {
        if (lastPickerOptions == null || lastPickerCallback == null) {
            throw new AssertionError("No active MobileBottomSheet picker for: " + needle);
        }
        for (int i = 0; i < lastPickerOptions.length; i++) {
            if (lastPickerOptions[i] != null && lastPickerOptions[i].contains(needle)) {
                PlayerBubble.IntAction cb = lastPickerCallback;
                cb.accept(i);
                return;
            }
        }
        throw new AssertionError("Picker option not found: " + needle + " in " + java.util.Arrays.toString(lastPickerOptions));
    }

    static void confirmPending() {
        if (lastConfirmCallback == null) {
            throw new AssertionError("No pending MobileBottomSheet confirm dialog");
        }
        Runnable cb = lastConfirmCallback;
        lastConfirmCallback = null;
        cb.run();
    }

    static Dialog show(MainActivity a, String title, View content) {
        return showHandle(a, title, null, null, null, content, true).dialog;
    }

    static Dialog show(
            MainActivity a,
            String title,
            String subtitle,
            String actionLabel,
            Runnable onAction,
            View content,
            boolean allowScroll) {
        return showHandle(a, title, subtitle, actionLabel, onAction, content, allowScroll).dialog;
    }

    static SheetHandle showCustom(MainActivity a, String title, View content, Runnable onDismiss) {
        return showHandle(a, title, null, null, null, content, true);
    }

    static SheetHandle showHandle(
            MainActivity a,
            String title,
            String subtitle,
            String actionLabel,
            Runnable onAction,
            View content,
            boolean allowScroll) {
        lastContent = content;
        return new SheetHandle();
    }

    static Dialog showPicker(
            MainActivity a,
            String title,
            String subtitle,
            String[] options,
            int selectedIndex,
            PlayerBubble.IntAction onSelect) {
        lastPickerOptions = options;
        lastPickerCallback = onSelect;
        return new Dialog();
    }

    static Dialog showConfirm(
            MainActivity a,
            String title,
            String message,
            String confirmLabel,
            boolean destructive,
            Runnable onConfirm) {
        lastConfirmCallback = onConfirm;
        return new Dialog();
    }
}
"""

TEST_DRIVER_JAVA = r"""package com.pilipala.marcomovie;

import android.view.View;
import android.widget.Button;
import android.widget.TextView;
import java.util.*;

public final class MobileDetailPrimaryButtonChecks {
    private static int passed = 0;

    private static void check(boolean cond, String msg) {
        if (!cond) throw new AssertionError("FAIL: " + msg);
        passed++;
        System.out.println("PASS " + msg);
    }

    private static Cms.Episode ep(String name, String url) {
        Cms.Episode e = new Cms.Episode();
        e.name = name;
        e.url = url;
        return e;
    }

    private static Cms.Line line(String name, Cms.Episode... eps) {
        Cms.Line l = new Cms.Line();
        l.lineId = name;
        l.name = name;
        l.rawName = name;
        l.episodes.addAll(Arrays.asList(eps));
        return l;
    }

    private static Cms.Line numberedLine(String name, String urlPrefix, int count) {
        Cms.Line l = new Cms.Line();
        l.lineId = name;
        l.name = name;
        l.rawName = name;
        for (int i = 1; i <= count; i++) {
            l.episodes.add(ep("第" + i + "集", urlPrefix + i));
        }
        return l;
    }

    private static Cms.Video video(String id, String title, Cms.Line... lines) {
        Cms.Video v = new Cms.Video();
        v.id = id;
        v.title = title;
        v.lines.addAll(Arrays.asList(lines));
        return v;
    }

    private static WatchHistory.Entry bookmark(
            String site, String id, String title, String lineName, String driveKey,
            String epName, String epUrl, int idx, int posMs) {
        WatchHistory.Entry e = new WatchHistory.Entry();
        e.site = site;
        e.id = id;
        e.title = title;
        e.line = lineName;
        e.lineId = lineName;
        e.driveKey = driveKey;
        e.episode = epName;
        e.episodeKey = WatchHistory.stableEpisodeKey(epUrl);
        e.index = idx;
        e.position = posMs;
        e.duration = 240_000;
        return e;
    }

    private static View findTextViewContaining(View v, String needle) {
        if (v instanceof TextView) {
            CharSequence t = ((TextView) v).getText();
            if (t != null && t.toString().contains(needle)) return v;
        }
        if (v instanceof android.view.ViewGroup) {
            android.view.ViewGroup vg = (android.view.ViewGroup) v;
            for (int i = 0; i < vg.getChildCount(); i++) {
                View f = findTextViewContaining(vg.getChildAt(i), needle);
                if (f != null) return f;
            }
        }
        return null;
    }

    public static void main(String[] args) {
        Cms.Site site = new Cms.Site();
        site.key = "site_main";
        site.name = "主站";
        site.type = 3;
        site.api = "csp_Demo";

        // =====================================================================
        // Criterion ①: Original Quark Ep 2 has 42s history; in default portrait mode (tapMode=0),
        //   tapping Quark Ep 1 card directly plays ONCE (Ep 1 @ 0ms) AND immediately syncs main
        //   button text, target, and resume position to Ep 1 @ 0ms!
        // =====================================================================
        Cms.Line qkS2 = line("夸克·第二季",
                ep("第1集", "https://pan.quark.cn/s/xt_qk_s2_e1"),
                ep("第2集", "https://pan.quark.cn/s/xt_qk_s2_e2"));
        Cms.Line bdS2 = line("百度·第二季",
                ep("第1集", "https://pan.baidu.com/s/xt_bd_s2_e1"),
                ep("第2集", "https://pan.baidu.com/s/xt_bd_s2_e2"));
        WatchHistory.Entry bmQuarkEp2 = bookmark(
                "site_main", "vod_xt", "星途 第二季", "夸克·第二季", NetdiskStore.DRIVE_QUARK,
                "第2集", "https://pan.quark.cn/s/xt_qk_s2_e2", 1, 42_000);

        MainActivity a1 = new MainActivity();
        a1.setupForTest(site, Collections.singletonList(bmQuarkEp2), video("vod_xt", "星途 第二季", qkS2, bdS2), 0);
        CatalogScreen.resumeHistory(a1, bmQuarkEp2);
        Button btn1 = (Button) a1.root.findViewWithTag("detail-play");
        check(
                btn1 != null && btn1.getText().toString().contains("播放 · 第 2 集") && a1.playCalls.isEmpty(),
                "C1-init: default portrait open shows '播放 · 第 2 集' with 0 play calls (label='" + btn1.getText() + "')");

        View qkCard1 = a1.root.findViewWithTag("ep-card:夸克·第二季:0");
        check(qkCard1 != null, "C1: Quark Ep 1 card exists");
        qkCard1.performClick();
        check(
                a1.playCalls.size() == 1
                        && "inline".equals(a1.playCalls.get(0).mode)
                        && "夸克·第二季".equals(a1.playCalls.get(0).line.name)
                        && "第1集".equals(a1.playCalls.get(0).ep.name)
                        && a1.playCalls.get(0).epNum == 1
                        && a1.playCalls.get(0).resumeAt == 0,
                "C1-card: direct tap on Quark Ep 1 card triggers strictly 1 inline play (夸克·第二季 / 第1集 / 0 ms)");
        check(
                btn1.getText().toString().contains("播放 · 第 1 集")
                        && !btn1.getText().toString().contains("第 2 集"),
                "C1-sync: main button text immediately updates to '播放 · 第 1 集' (actual='" + btn1.getText() + "')");
        btn1.performClick();
        check(
                a1.playCalls.size() == 2
                        && "inline".equals(a1.playCalls.get(1).mode)
                        && "夸克·第二季".equals(a1.playCalls.get(1).line.name)
                        && "第1集".equals(a1.playCalls.get(1).ep.name)
                        && a1.playCalls.get(1).epNum == 1
                        && a1.playCalls.get(1).resumeAt == 0,
                "C1-main: clicking synced main button plays 夸克·第二季 / 第1集 / 0 ms (calls=2)");

        // =====================================================================
        // Criterion ②: Original Quark vanished, site only has Baidu [第1集, 第2集];
        //   before selection main button prompts re-select with 0 plays;
        //   tapping Baidu Ep 1 card directly plays ONCE (百度·第二季 / 第1集 / 0 ms) AND updates main
        //   button so clicking main button continues playing Baidu Ep 1 instead of prompting re-select!
        // =====================================================================
        MainActivity a2 = new MainActivity();
        a2.setupForTest(site, Collections.singletonList(bmQuarkEp2), video("vod_xt", "星途 第二季", bdS2), 0);
        CatalogScreen.resumeHistory(a2, bmQuarkEp2);
        Button btn2 = (Button) a2.root.findViewWithTag("detail-play");
        check(
                btn2 != null && btn2.getText().toString().contains("原线路已变更") && btn2.getText().toString().contains("重选"),
                "C2-init: missing Quark prompts re-selection (label='" + btn2.getText() + "')");
        btn2.performClick();
        check(
                a2.playCalls.isEmpty() && a2.inlinePlayer == null && a2.resumeAt == 0 && a2.toasts.size() == 1,
                "C2-pre: clicking main button before selection triggers 0 play calls & emits prompt");

        View bdCard1 = a2.root.findViewWithTag("ep-card:百度·第二季:0");
        check(bdCard1 != null, "C2: Baidu Ep 1 card exists");
        bdCard1.performClick();
        check(
                a2.playCalls.size() == 1
                        && "inline".equals(a2.playCalls.get(0).mode)
                        && "百度·第二季".equals(a2.playCalls.get(0).line.name)
                        && "第1集".equals(a2.playCalls.get(0).ep.name)
                        && a2.playCalls.get(0).epNum == 1
                        && a2.playCalls.get(0).resumeAt == 0,
                "C2-card: direct tap on Baidu Ep 1 card triggers strictly 1 play (百度·第二季 / 第1集 / 0 ms)");
        check(
                btn2.getText().toString().contains("播放 · 第 1 集")
                        && !btn2.getText().toString().contains("重选"),
                "C2-sync: main button updates to '播放 · 第 1 集' and no longer prompts re-selection (actual='" + btn2.getText() + "')");
        int toastsBeforeBtn2 = a2.toasts.size();
        btn2.performClick();
        check(
                a2.playCalls.size() == 2
                        && "百度·第二季".equals(a2.playCalls.get(1).line.name)
                        && "第1集".equals(a2.playCalls.get(1).ep.name)
                        && a2.playCalls.get(1).resumeAt == 0
                        && a2.toasts.size() == toastsBeforeBtn2,
                "C2-main: clicking main button after tapping Baidu card plays 百度·第二季 / 第1集 / 0 ms without re-select prompt");

        // Also single-episode movie (春潮) missing Quark -> direct tap on Baidu 正片 card syncs main button!
        Cms.Line bdMovie = line("百度", ep("正片", "https://pan.baidu.com/s/cc_bd"));
        Cms.Line qkMovie = line("夸克", ep("正片", "https://pan.quark.cn/s/cc_qk"));
        WatchHistory.Entry bmMovie = bookmark(
                "site_main", "vod_cc", "春潮", "夸克", NetdiskStore.DRIVE_QUARK,
                "正片", "https://pan.quark.cn/s/cc_qk", 0, 42_000);
        MainActivity a2m = new MainActivity();
        a2m.setupForTest(site, Collections.singletonList(bmMovie), video("vod_cc", "春潮", bdMovie), 0);
        CatalogScreen.resumeHistory(a2m, bmMovie);
        Button btn2m = (Button) a2m.root.findViewWithTag("detail-play");
        btn2m.performClick();
        check(
                a2m.playCalls.isEmpty() && btn2m.getText().toString().contains("重选"),
                "C2-movie-pre: missing Quark movie prompts re-select with 0 play calls");
        View bdMovieCard = a2m.root.findViewWithTag("ep-card:百度:0");
        bdMovieCard.performClick();
        check(
                a2m.playCalls.size() == 1
                        && "百度".equals(a2m.playCalls.get(0).line.name)
                        && "正片".equals(a2m.playCalls.get(0).ep.name)
                        && a2m.playCalls.get(0).resumeAt == 0
                        && btn2m.getText().toString().contains("播放 · 正片"),
                "C2-movie-card: direct tap on Baidu 正片 card plays once (0 ms) and syncs main button to '播放 · 正片'");
        btn2m.performClick();
        check(
                a2m.playCalls.size() == 2
                        && "百度".equals(a2m.playCalls.get(1).line.name)
                        && "正片".equals(a2m.playCalls.get(1).ep.name)
                        && a2m.playCalls.get(1).resumeAt == 0,
                "C2-movie-main: clicking synced movie main button plays 百度 / 正片 / 0 ms");

        // =====================================================================
        // Criterion ③: Hand-select 阿里云·第二季 Ep 2 (and also page 1 / Ep 52!), THEN deliver
        //   background populateRelatedSeasons result -> refresh preserves line, episode, page,
        //   does NOT trigger playback, and main button still plays 阿里云·第二季 Ep 2 @ 0 ms!
        // =====================================================================
        SourceController.nextSearchJson =
                "{\"list\":[{\"vod_id\":\"vod_xt_s1\",\"vod_name\":\"星途 第一季\"},{\"vod_id\":\"vod_xt\",\"vod_name\":\"星途 第二季\"}]}";
        Cms.Line qkS2Long = numberedLine("夸克·第二季", "https://pan.quark.cn/s/xt_qk_s2_e", 60);
        Cms.Line bdS2Long = numberedLine("百度·第二季", "https://pan.baidu.com/s/xt_bd_s2_e", 60);
        Cms.Line aliS2Long = numberedLine("阿里云·第二季", "https://www.alipan.com/s/xt_ali_s2_e", 60);

        MainActivity a3 = new MainActivity();
        a3.setupForTest(
                site,
                Collections.singletonList(bmQuarkEp2),
                video("vod_xt", "星途 第二季", qkS2Long, bdS2Long, aliS2Long),
                0);
        CatalogScreen.resumeHistory(a3, bmQuarkEp2);
        Button btn3 = (Button) a3.root.findViewWithTag("detail-play");
        check(!a3.deferredPageTasks.isEmpty(), "C3a: populateRelatedSeasons background task queued");

        // User manually selects 阿里云·第二季 line pill, then selects Episode 2 pill
        View aliLinePill = findTextViewContaining(a3.root, "阿里云·第二季 · 60");
        check(aliLinePill != null, "C3a: 阿里云·第二季 line pill exists");
        aliLinePill.performClick();
        View aliEp2Pill = a3.root.findViewWithTag("episode:阿里云·第二季:1");
        check(aliEp2Pill != null, "C3a: 阿里云·第二季 Ep 2 pill exists");
        aliEp2Pill.performClick();
        check(
                btn3.getText().toString().contains("播放 · 第 2 集") && a3.playCalls.isEmpty(),
                "C3a-pre: after selecting 阿里云·第二季 Ep 2, main button='播放 · 第 2 集' and playCalls=0");

        // Now deliver delayed background related-seasons search result!
        a3.runDeferredPageTasksAndFlushUi();
        check(
                a3.playCalls.isEmpty(),
                "C3a-refresh: delivering background related-seasons result triggers 0 play calls");
        check(
                a3.root.findViewWithTag("detail-season:1") != null
                        && a3.root.findViewWithTag("detail-season:2") != null,
                "C3a-seasons: related-seasons strip (第 1 季 + 第 2 季) rendered");
        TextView topSrc3 = (TextView) a3.root.findViewWithTag("detail-source-picker");
        check(
                topSrc3 != null
                        && "阿里云·第二季".equals(topSrc3.getText().toString())
                        && a3.root.findViewWithTag("episode:阿里云·第二季:1") != null,
                "C3a-keep-line: refresh preserved active line 阿里云·第二季 and page 0 (actual topSrc='" + (topSrc3 == null ? "null" : topSrc3.getText()) + "')");
        check(
                btn3.getText().toString().contains("播放 · 第 2 集"),
                "C3a-keep-btn: main button still says '播放 · 第 2 集' (actual='" + btn3.getText() + "')");
        btn3.performClick();
        check(
                a3.playCalls.size() == 1
                        && "阿里云·第二季".equals(a3.playCalls.get(0).line.name)
                        && "第2集".equals(a3.playCalls.get(0).ep.name)
                        && a3.playCalls.get(0).epNum == 2
                        && a3.playCalls.get(0).resumeAt == 0,
                "C3a-play: clicking main button after related-seasons refresh plays 阿里云·第二季 / 第2集 / 0 ms (calls=1)");

        // C3b: Pagination preservation across related-seasons refresh (page 1: 51 · 60, Ep 52!)
        MainActivity a3b = new MainActivity();
        a3b.setupForTest(
                site,
                Collections.singletonList(bmQuarkEp2),
                video("vod_xt", "星途 第二季", qkS2Long, bdS2Long, aliS2Long),
                0);
        CatalogScreen.resumeHistory(a3b, bmQuarkEp2);
        Button btn3b = (Button) a3b.root.findViewWithTag("detail-play");
        findTextViewContaining(a3b.root, "阿里云·第二季 · 60").performClick();
        View page2Tab = findTextViewContaining(a3b.root, "51 · 60");
        check(page2Tab != null, "C3b: page tab '51 · 60' exists");
        page2Tab.performClick();
        View aliEp52Pill = a3b.root.findViewWithTag("episode:阿里云·第二季:51");
        check(aliEp52Pill != null, "C3b: Ep 52 pill visible on page 1");
        aliEp52Pill.performClick();
        a3b.runDeferredPageTasksAndFlushUi();
        check(
                a3b.playCalls.isEmpty()
                        && a3b.root.findViewWithTag("episode:阿里云·第二季:51") != null
                        && btn3b.getText().toString().contains("播放 · 第 52 集"),
                "C3b-refresh: related-seasons refresh preserves page 1 (51·60), active line 阿里云·第二季, Ep 52, with 0 play calls");
        btn3b.performClick();
        check(
                a3b.playCalls.size() == 1
                        && "阿里云·第二季".equals(a3b.playCalls.get(0).line.name)
                        && "第52集".equals(a3b.playCalls.get(0).ep.name)
                        && a3b.playCalls.get(0).epNum == 52
                        && a3b.playCalls.get(0).resumeAt == 0,
                "C3b-play: clicking main button plays 阿里云·第二季 / 第52集 / 0 ms");

        // =====================================================================
        // Criterion ④: Preserve (a) present original Quark resume 42000ms, (b) cross-site failover
        //   42000ms, and (c) switching to another video clears manual selection state & drops stale
        //   related-seasons callbacks from previous video!
        // =====================================================================
        MainActivity a4 = new MainActivity();
        a4.setupForTest(site, Collections.singletonList(bmQuarkEp2), video("vod_xt", "星途 第二季", bdS2, qkS2), 0);
        CatalogScreen.resumeHistory(a4, bmQuarkEp2);
        Button btn4 = (Button) a4.root.findViewWithTag("detail-play");
        check(btn4.getText().toString().contains("播放 · 第 2 集"), "C4a-init: present Quark resumes Ep 2");
        btn4.performClick();
        check(
                a4.playCalls.size() == 1
                        && "夸克·第二季".equals(a4.playCalls.get(0).line.name)
                        && "第2集".equals(a4.playCalls.get(0).ep.name)
                        && a4.playCalls.get(0).resumeAt == 42_000,
                "C4a-quark: present Quark series resumes 夸克·第二季 / 第2集 / 42000 ms");

        // Present Quark single-episode movie
        MainActivity a4m = new MainActivity();
        a4m.setupForTest(site, Collections.singletonList(bmMovie), video("vod_cc", "春潮", bdMovie, qkMovie), 0);
        CatalogScreen.resumeHistory(a4m, bmMovie);
        Button btn4m = (Button) a4m.root.findViewWithTag("detail-play");
        btn4m.performClick();
        check(
                a4m.playCalls.size() == 1
                        && "夸克".equals(a4m.playCalls.get(0).line.name)
                        && "正片".equals(a4m.playCalls.get(0).ep.name)
                        && a4m.playCalls.get(0).resumeAt == 42_000,
                "C4a-movie: present Quark movie resumes 夸克 / 正片 / 42000 ms");

        // Cross-site failover for series & movie -> 42000 ms
        HistoryResumeMatcher.EpisodeMatch crossSeries =
                HistoryResumeMatcher.matchEpisodeForFailover(video("alt_xt", "星途 第二季", bdS2), bmQuarkEp2);
        HistoryResumeMatcher.EpisodeMatch crossMovie =
                HistoryResumeMatcher.matchEpisodeForFailover(video("alt_cc", "春潮", bdMovie), bmMovie);
        check(
                crossSeries != null
                        && "百度·第二季".equals(crossSeries.line.name)
                        && "第2集".equals(crossSeries.episode.name)
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(crossSeries, bmQuarkEp2) == 42_000
                        && crossMovie != null
                        && "百度".equals(crossMovie.line.name)
                        && "正片".equals(crossMovie.episode.name)
                        && HistoryResumeMatcher.resolveFailoverResumePositionMs(crossMovie, bmMovie) == 42_000,
                "C4b-cross: cross-site failover recovers 42000 ms for both series & movie");

        // Video switch clears previous video's manual selection state AND ignores stale season callback!
        WatchHistory.Entry bmOtherMissing = bookmark(
                "site_main", "vod_other", "长河", "夸克", NetdiskStore.DRIVE_QUARK,
                "第2集", "https://pan.quark.cn/s/ch_qk_e2", 1, 42_000);
        Cms.Line otherBdLine = line("百度",
                ep("第1集", "https://pan.baidu.com/s/ch_bd_e1"),
                ep("第2集", "https://pan.baidu.com/s/ch_bd_e2"));
        MainActivity aSwitch = new MainActivity();
        aSwitch.setupForTest(
                site,
                Arrays.asList(bmQuarkEp2, bmOtherMissing),
                video("vod_xt", "星途 第二季", bdS2, aliS2Long),
                0);
        CatalogScreen.resumeHistory(aSwitch, bmQuarkEp2);
        // Hand-select Baidu Ep 1 on Video A while Video A's related-seasons search is still pending!
        View vACard1 = aSwitch.root.findViewWithTag("ep-card:百度·第二季:0");
        vACard1.performClick();
        check(aSwitch.playCalls.size() == 1, "C4c-videoA: hand-tapping card on Video A starts 1 play");
        List<Runnable> staleSeasonTasks = new ArrayList<>(aSwitch.deferredPageTasks);
        aSwitch.deferredPageTasks.clear();

        // Now switch to Video B (长河, whose Quark vanished and only Baidu remains!)
        aSwitch.readyDetailVideo = video("vod_other", "长河", otherBdLine);
        aSwitch.playCalls.clear();
        CatalogScreen.resumeHistory(aSwitch, bmOtherMissing);
        // Fire Video A's stale related-seasons task AFTER switching to Video B -> must be ignored!
        for (Runnable r : staleSeasonTasks) r.run();
        android.os.Handler.flushPending();
        Button btnB = (Button) aSwitch.root.findViewWithTag("detail-play");
        check(
                btnB != null
                        && btnB.getText().toString().contains("原线路已变更")
                        && btnB.getText().toString().contains("重选"),
                "C4c-videoB: switching to Video B clears Video A's manual selection state (label='" + btnB.getText() + "')");
        btnB.performClick();
        check(
                aSwitch.playCalls.isEmpty() && aSwitch.resumeAt == 0,
                "C4c-videoB-click: Video B prompts re-selection with 0 play calls (stale callback ignored)");

        // =====================================================================
        // Round-13 P2: Line management (pin/move/hide) via BOTH long-press quick line pill AND
        //   top source picker 「管理」 button rebinds active line, episode, page, top bar & primary
        //   button by stable lineId, with 0 play calls during management and strictly 1 play on click!
        // =====================================================================
        WatchHistory.Entry bmQuarkEp1 = bookmark(
                "site_main", "vod_r13", "青岚", "夸克", NetdiskStore.DRIVE_QUARK,
                "第1集", "https://pan.quark.cn/s/ql_qk_e1", 0, 42_000);

        // R13-1a: History=夸克 第1集 42s; hand-select 夸克 第2集 -> LONG-PRESS 百度 pill -> Pin 百度 to top
        {
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 60);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 60);
            Cms.Video v = video("vod_r13", "青岚", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmQuarkEp1), v, 0);
            CatalogScreen.resumeHistory(act, bmQuarkEp1);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            act.root.findViewWithTag("episode:夸克:1").performClick();
            check(
                    btn.getText().toString().contains("播放 · 第 2 集") && act.playCalls.isEmpty(),
                    "R13-1a-pre: selected 夸克 第2集 before pinning 百度 (calls=0)");
            View bdPill = act.root.findViewWithTag("detail-line-pill:百度");
            check(bdPill != null && bdPill.performLongClick(), "R13-1a: long-press 百度 line pill opens manage sheet");
            MobileBottomSheet.pickOptionContaining("置顶此线路");
            TextView topSrc = (TextView) act.root.findViewWithTag("detail-source-picker");
            check(
                    act.playCalls.isEmpty()
                            && "百度".equals(v.lines.get(0).lineId())
                            && "夸克".equals(v.lines.get(1).lineId())
                            && topSrc != null && "夸克".equals(topSrc.getText().toString())
                            && btn.getText().toString().contains("播放 · 第 2 集"),
                    "R13-1a-reorder: long-press pin 百度 -> 0 plays, lines=[百度,夸克], topSrc='夸克', btn='播放 · 第 2 集'");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "夸克".equals(act.playCalls.get(0).line.name)
                            && "第2集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 2
                            && act.playCalls.get(0).resumeAt == 0,
                    "R13-1a-play: main button plays 夸克 / 第2集 / 0 ms (calls=1)");
        }

        // R13-1b: History=夸克 第1集 42s; hand-select 夸克 第2集 -> TOP PICKER 「管理」 on 百度 -> Pin 百度 to top
        {
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 60);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 60);
            Cms.Video v = video("vod_r13", "青岚", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmQuarkEp1), v, 0);
            CatalogScreen.resumeHistory(act, bmQuarkEp1);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            act.root.findViewWithTag("episode:夸克:1").performClick();
            act.root.findViewWithTag("detail-source-pill").performClick();
            View manageBd = MobileBottomSheet.lastContent.findViewWithTag("line-picker-manage:百度");
            check(manageBd != null, "R13-1b: top picker 百度「管理」button exists");
            manageBd.performClick();
            MobileBottomSheet.pickOptionContaining("置顶此线路");
            TextView topSrc = (TextView) act.root.findViewWithTag("detail-source-picker");
            check(
                    act.playCalls.isEmpty()
                            && "百度".equals(v.lines.get(0).lineId())
                            && "夸克".equals(v.lines.get(1).lineId())
                            && topSrc != null && "夸克".equals(topSrc.getText().toString())
                            && btn.getText().toString().contains("播放 · 第 2 集"),
                    "R13-1b-reorder: top picker「管理」pin 百度 -> 0 plays, lines=[百度,夸克], topSrc='夸克', btn='播放 · 第 2 集'");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "夸克".equals(act.playCalls.get(0).line.name)
                            && "第2集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 2
                            && act.playCalls.get(0).resumeAt == 0,
                    "R13-1b-play: main button plays 夸克 / 第2集 / 0 ms (calls=1)");
        }

        // R13-1c: Pagination preservation across line reorder (page 1: 51·60, 夸克 第52集 -> pin 百度)
        {
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 60);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 60);
            Cms.Video v = video("vod_r13", "青岚", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmQuarkEp1), v, 0);
            CatalogScreen.resumeHistory(act, bmQuarkEp1);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            findTextViewContaining(act.root, "51 · 60").performClick();
            act.root.findViewWithTag("episode:夸克:51").performClick();
            act.root.findViewWithTag("detail-source-pill").performClick();
            MobileBottomSheet.lastContent.findViewWithTag("line-picker-manage:百度").performClick();
            MobileBottomSheet.pickOptionContaining("置顶此线路");
            TextView topSrc = (TextView) act.root.findViewWithTag("detail-source-picker");
            check(
                    act.playCalls.isEmpty()
                            && topSrc != null && "夸克".equals(topSrc.getText().toString())
                            && act.root.findViewWithTag("episode:夸克:51") != null
                            && btn.getText().toString().contains("播放 · 第 52 集"),
                    "R13-1c-page: pin 百度 preserves page 1 (51·60), topSrc='夸克', Ep 52 & 0 plays");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "夸克".equals(act.playCalls.get(0).line.name)
                            && "第52集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 52
                            && act.playCalls.get(0).resumeAt == 0,
                    "R13-1c-play: main button plays 夸克 / 第52集 / 0 ms (calls=1)");
        }

        // R13-2a: Hand-select 百度 第2集 -> Pin 百度 to top (BOTH long-press pill & top picker「管理」)
        for (int entryMode = 0; entryMode < 2; entryMode++) {
            String tag = entryMode == 0 ? "R13-2a-longpress" : "R13-2a-toppicker";
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 10);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 10);
            Cms.Video v = video("vod_r13", "青岚", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmQuarkEp1), v, 0);
            CatalogScreen.resumeHistory(act, bmQuarkEp1);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            act.root.findViewWithTag("detail-line-pill:百度").performClick();
            act.root.findViewWithTag("episode:百度:1").performClick();
            if (entryMode == 0) {
                act.root.findViewWithTag("detail-line-pill:百度").performLongClick();
            } else {
                act.root.findViewWithTag("detail-source-pill").performClick();
                MobileBottomSheet.lastContent.findViewWithTag("line-picker-manage:百度").performClick();
            }
            MobileBottomSheet.pickOptionContaining("置顶此线路");
            TextView topSrc = (TextView) act.root.findViewWithTag("detail-source-picker");
            check(
                    act.playCalls.isEmpty()
                            && "百度".equals(v.lines.get(0).lineId())
                            && topSrc != null && "百度".equals(topSrc.getText().toString())
                            && btn.getText().toString().contains("播放 · 第 2 集"),
                    tag + "-reorder: pin 百度 -> 0 plays, topSrc='百度', btn='播放 · 第 2 集'");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "百度".equals(act.playCalls.get(0).line.name)
                            && "第2集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 2
                            && act.playCalls.get(0).resumeAt == 0,
                    tag + "-play: main button plays 百度 / 第2集 / 0 ms (calls=1)");
        }

        // R13-2b: Hand-select 百度 第2集 -> Hide the OTHER line 夸克 (BOTH long-press reused pill & top picker「管理」)
        for (int entryMode = 0; entryMode < 2; entryMode++) {
            String tag = entryMode == 0 ? "R13-2b-longpress" : "R13-2b-toppicker";
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 10);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 10);
            Cms.Video v = video("vod_r13", "青岚", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmQuarkEp1), v, 0);
            CatalogScreen.resumeHistory(act, bmQuarkEp1);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            act.root.findViewWithTag("detail-line-pill:百度").performClick();
            act.root.findViewWithTag("episode:百度:1").performClick();
            if (entryMode == 0) {
                act.root.findViewWithTag("detail-line-pill:夸克").performLongClick();
            } else {
                act.root.findViewWithTag("detail-source-pill").performClick();
                MobileBottomSheet.lastContent.findViewWithTag("line-picker-manage:夸克").performClick();
            }
            MobileBottomSheet.pickOptionContaining("删除（隐藏）此线路");
            MobileBottomSheet.confirmPending();
            TextView topSrc = (TextView) act.root.findViewWithTag("detail-source-picker");
            check(
                    act.playCalls.isEmpty()
                            && v.lines.size() == 1
                            && "百度".equals(v.lines.get(0).lineId())
                            && topSrc != null && "换源".equals(topSrc.getText().toString())
                            && act.root.findViewWithTag("episode:百度:1") != null
                            && btn.getText().toString().contains("播放 · 第 2 集"),
                    tag + "-hide: hiding other line 夸克 -> 0 plays, lines=[百度], topSrc='换源', btn='播放 · 第 2 集'");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "百度".equals(act.playCalls.get(0).line.name)
                            && "第2集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 2
                            && act.playCalls.get(0).resumeAt == 0,
                    tag + "-play: main button plays 百度 / 第2集 / 0 ms (calls=1)");
        }

        // R13-2c: Move another line up in 3-line [夸克, 百度, 阿里] while 百度 第2集 is selected + Hide active line resets safely
        {
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 10);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 10);
            Cms.Line ali = numberedLine("阿里", "https://www.alipan.com/s/ql_ali_e", 10);
            Cms.Video v = video("vod_r13", "青岚", qk, bd, ali);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmQuarkEp1), v, 0);
            CatalogScreen.resumeHistory(act, bmQuarkEp1);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            act.root.findViewWithTag("detail-line-pill:百度").performClick();
            act.root.findViewWithTag("episode:百度:1").performClick();
            act.root.findViewWithTag("detail-line-pill:阿里").performLongClick();
            MobileBottomSheet.pickOptionContaining("上移一位");
            TextView topSrc = (TextView) act.root.findViewWithTag("detail-source-picker");
            check(
                    act.playCalls.isEmpty()
                            && "阿里".equals(v.lines.get(1).lineId())
                            && "百度".equals(v.lines.get(2).lineId())
                            && topSrc != null && "百度".equals(topSrc.getText().toString())
                            && btn.getText().toString().contains("播放 · 第 2 集"),
                    "R13-2c-move: moving 阿里 up shifts 百度 to idx 2 -> 0 plays, topSrc='百度', btn='播放 · 第 2 集'");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "百度".equals(act.playCalls.get(0).line.name)
                            && "第2集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).resumeAt == 0,
                    "R13-2c-play: main button plays 百度 / 第2集 / 0 ms (calls=1)");
        }

        // R13-2d: Hiding the CURRENTLY active line (夸克) clears stale manual selection & prompts re-select on remaining 百度
        {
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 10);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 10);
            Cms.Video v = video("vod_r13", "青岚", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmQuarkEp1), v, 0);
            CatalogScreen.resumeHistory(act, bmQuarkEp1);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            act.root.findViewWithTag("episode:夸克:1").performClick();
            act.root.findViewWithTag("detail-line-pill:夸克").performLongClick();
            MobileBottomSheet.pickOptionContaining("删除（隐藏）此线路");
            MobileBottomSheet.confirmPending();
            check(
                    act.playCalls.isEmpty()
                            && v.lines.size() == 1
                            && "百度".equals(v.lines.get(0).lineId())
                            && btn.getText().toString().contains("原线路已变更")
                            && btn.getText().toString().contains("重选"),
                    "R13-2d-hide-active: hiding active 夸克 clears stale selection & prompts re-selection on remaining 百度 (0 plays)");
            btn.performClick();
            check(
                    act.playCalls.isEmpty() && act.resumeAt == 0,
                    "R13-2d-click: clicking prompt after hiding active 夸克 triggers 0 plays");
        }

        // =====================================================================
        // Round-14 P2: Hiding the currently hand-selected line MUST hold awaiting-reselection
        //   (0 plays, resumeAt=0, re-selection prompt) across ALL 3 history states (history on
        //   other remaining line 夸克, no history, history on hidden 百度), via BOTH long-press
        //   pill & top picker 「管理」, persisting across page flips & delayed related-seasons
        //   refresh, until user explicitly picks a line/episode!
        // =====================================================================
        WatchHistory.Entry bmBaiduEp2 = bookmark(
                "site_main", "vod_r13", "青岚", "百度", NetdiskStore.DRIVE_BAIDU,
                "第2集", "https://pan.baidu.com/s/ql_bd_e2", 1, 42_000);

        // R14-1: 2 entry modes (long-press pill & top picker 「管理」) × 3 history states
        //   (0 = history on 夸克, 1 = no history, 2 = history on 百度) -> hide hand-selected 百度
        for (int entryMode = 0; entryMode < 2; entryMode++) {
            String entryTag = entryMode == 0 ? "longpress" : "toppicker";
            for (int histCase = 0; histCase < 3; histCase++) {
                String histTag = histCase == 0 ? "histQuark" : (histCase == 1 ? "noHist" : "histBaidu");
                String tag = "R14-1-" + entryTag + "-" + histTag;
                MobileBottomSheet.resetForTest();
                Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/ql_qk_e", 10);
                Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/ql_bd_e", 10);
                Cms.Video v = video("vod_r13", "青岚", qk, bd);
                List<WatchHistory.Entry> histList =
                        histCase == 0
                                ? Collections.singletonList(bmQuarkEp1)
                                : (histCase == 1
                                        ? Collections.<WatchHistory.Entry>emptyList()
                                        : Collections.singletonList(bmBaiduEp2));
                MainActivity act = new MainActivity();
                act.setupForTest(site, histList, v, 0);
                if (histCase == 0) {
                    CatalogScreen.resumeHistory(act, bmQuarkEp1);
                } else if (histCase == 1) {
                    act.detail(site, v);
                } else {
                    CatalogScreen.resumeHistory(act, bmBaiduEp2);
                }
                Button btn = (Button) act.root.findViewWithTag("detail-play");
                // Explicitly hand-select 百度 line and 百度 第2集
                act.root.findViewWithTag("detail-line-pill:百度").performClick();
                act.root.findViewWithTag("episode:百度:1").performClick();
                // Pre-seed a non-zero resumeAt to prove hide itself clears resumeAt back to 0!
                act.resumeAt = 42_000;
                if (entryMode == 0) {
                    act.root.findViewWithTag("detail-line-pill:百度").performLongClick();
                } else {
                    act.root.findViewWithTag("detail-source-pill").performClick();
                    MobileBottomSheet.lastContent.findViewWithTag("line-picker-manage:百度").performClick();
                }
                MobileBottomSheet.pickOptionContaining("删除（隐藏）此线路");
                MobileBottomSheet.confirmPending();
                check(
                        act.playCalls.isEmpty()
                                && act.resumeAt == 0
                                && v.lines.size() == 1
                                && "夸克".equals(v.lines.get(0).lineId())
                                && btn.getText().toString().contains("原线路已变更")
                                && btn.getText().toString().contains("重选"),
                        tag + "-hidden: hiding hand-selected 百度 holds awaiting-reselect (0 plays, resumeAt=0, label='" + btn.getText() + "')");
                int toastsBefore = act.toasts.size();
                btn.performClick();
                check(
                        act.playCalls.isEmpty()
                                && act.resumeAt == 0
                                && act.toasts.size() == toastsBefore + 1
                                && MobileDetailScreen.RESELECT_TOAST_TEXT.equals(
                                        act.toasts.get(act.toasts.size() - 1)),
                        tag + "-click: clicking main button after hiding 百度 triggers 0 plays, resumeAt=0 & re-select prompt");
            }
        }

        // R14-2: 3-line [夸克(60), 百度(60), 阿里(60)] and [百度(60), 夸克(60), 阿里(60)] with history
        //   on 夸克 & pending related seasons: hide hand-selected 百度 (BOTH entry modes) -> flip
        //   page (51·60) -> deliver related seasons -> still awaiting re-select (0 plays,
        //   resumeAt=0) -> explicitly pick 阿里 第3集 -> click main button -> strictly 1 play:
        //   阿里 / 第3集 / 0 ms!
        SourceController.nextSearchJson =
                "{\"list\":[{\"vod_id\":\"vod_r14_s1\",\"vod_name\":\"星途 第一季\"},{\"vod_id\":\"vod_r14_s2\",\"vod_name\":\"星途 第二季\"}]}";
        WatchHistory.Entry bmR14Quark = bookmark(
                "site_main", "vod_r14_s2", "星途 第二季", "夸克", NetdiskStore.DRIVE_QUARK,
                "第1集", "https://pan.quark.cn/s/r14_qk_e1", 0, 42_000);
        for (int entryMode = 0; entryMode < 2; entryMode++) {
            String tag = entryMode == 0 ? "R14-2-longpress" : "R14-2-toppicker";
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/r14_qk_e", 60);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/r14_bd_e", 60);
            Cms.Line ali = numberedLine("阿里", "https://www.alipan.com/s/r14_ali_e", 60);
            Cms.Video v =
                    entryMode == 0
                            ? video("vod_r14_s2", "星途 第二季", qk, bd, ali)
                            : video("vod_r14_s2", "星途 第二季", bd, qk, ali);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.singletonList(bmR14Quark), v, 0);
            CatalogScreen.resumeHistory(act, bmR14Quark);
            check(!act.deferredPageTasks.isEmpty(), tag + ": related-seasons task queued");
            Button btn = (Button) act.root.findViewWithTag("detail-play");

            // Hand-select 百度 第2集 then hide 百度
            act.root.findViewWithTag("detail-line-pill:百度").performClick();
            act.root.findViewWithTag("episode:百度:1").performClick();
            if (entryMode == 0) {
                act.root.findViewWithTag("detail-line-pill:百度").performLongClick();
            } else {
                act.root.findViewWithTag("detail-source-pill").performClick();
                MobileBottomSheet.lastContent.findViewWithTag("line-picker-manage:百度").performClick();
            }
            MobileBottomSheet.pickOptionContaining("删除（隐藏）此线路");
            MobileBottomSheet.confirmPending();
            check(
                    act.playCalls.isEmpty()
                            && act.resumeAt == 0
                            && v.lines.size() == 2
                            && "夸克".equals(v.lines.get(0).lineId())
                            && "阿里".equals(v.lines.get(1).lineId())
                            && btn.getText().toString().contains("原线路已变更")
                            && btn.getText().toString().contains("重选"),
                    tag + "-hidden: 3-line hide 百度 leaves [夸克,阿里] awaiting re-select (0 plays, resumeAt=0)");

            // Flip page to 51 · 60 while awaiting re-select -> MUST remain awaiting re-select!
            View p2Tab = findTextViewContaining(act.root, "51 · 60");
            check(p2Tab != null, tag + ": page tab '51 · 60' exists");
            p2Tab.performClick();
            int toastsBeforePageClick = act.toasts.size();
            btn.performClick();
            check(
                    act.playCalls.isEmpty()
                            && act.resumeAt == 0
                            && btn.getText().toString().contains("重选")
                            && act.toasts.size() == toastsBeforePageClick + 1
                            && MobileDetailScreen.RESELECT_TOAST_TEXT.equals(
                                    act.toasts.get(act.toasts.size() - 1)),
                    tag + "-after-page: page flip keeps awaiting re-select (0 plays, resumeAt=0)");

            // Deliver delayed related-seasons result -> MUST STILL remain awaiting re-select!
            act.runDeferredPageTasksAndFlushUi();
            int toastsBeforeSeasonClick = act.toasts.size();
            btn.performClick();
            check(
                    act.playCalls.isEmpty()
                            && act.resumeAt == 0
                            && act.root.findViewWithTag("detail-season:1") != null
                            && act.root.findViewWithTag("detail-season:2") != null
                            && btn.getText().toString().contains("重选")
                            && act.toasts.size() == toastsBeforeSeasonClick + 1
                            && MobileDetailScreen.RESELECT_TOAST_TEXT.equals(
                                    act.toasts.get(act.toasts.size() - 1)),
                    tag + "-after-seasons: related-seasons refresh keeps awaiting re-select (0 plays, resumeAt=0)");

            // Explicitly switch to 阿里 and select 第3集 -> main button updates; click dispatches 阿里/第3集/0ms ONCE!
            act.root.findViewWithTag("detail-line-pill:阿里").performClick();
            act.root.findViewWithTag("episode:阿里:2").performClick();
            check(
                    act.playCalls.isEmpty() && btn.getText().toString().contains("播放 · 第 3 集"),
                    tag + "-select-ali3: selecting 阿里 第3集 updates main button without auto-playing");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "阿里".equals(act.playCalls.get(0).line.name)
                            && "第3集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 3
                            && act.playCalls.get(0).resumeAt == 0,
                    tag + "-play-ali3: clicking main button dispatches 阿里 / 第3集 / 0 ms strictly once");
        }

        // R14-3a: Normal first open of a video with NO history still plays Ep 1 @ 0ms directly!
        {
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/fresh_qk_e", 10);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/fresh_bd_e", 10);
            Cms.Video v = video("vod_fresh", "清风", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.<WatchHistory.Entry>emptyList(), v, 0);
            act.detail(site, v);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            check(
                    act.playCalls.isEmpty()
                            && btn != null
                            && btn.getText().toString().contains("播放 · 第 1 集")
                            && !btn.getText().toString().contains("重选"),
                    "R14-3a-open: fresh no-history open shows '播放 · 第 1 集' directly (0 plays)");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "夸克".equals(act.playCalls.get(0).line.name)
                            && "第1集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 1
                            && act.playCalls.get(0).resumeAt == 0,
                    "R14-3a-play: clicking main button on fresh no-history video plays 夸克 / 第1集 / 0 ms directly");
        }

        // R14-3b: Hiding a NON-CURRENT line while on page 1 (51·60) preserves hand-selected target & page!
        {
            MobileBottomSheet.resetForTest();
            Cms.Line qk = numberedLine("夸克", "https://pan.quark.cn/s/r14_page_qk_e", 60);
            Cms.Line bd = numberedLine("百度", "https://pan.baidu.com/s/r14_page_bd_e", 60);
            Cms.Video v = video("vod_r14_page", "山海", qk, bd);
            MainActivity act = new MainActivity();
            act.setupForTest(site, Collections.<WatchHistory.Entry>emptyList(), v, 0);
            act.detail(site, v);
            Button btn = (Button) act.root.findViewWithTag("detail-play");
            findTextViewContaining(act.root, "51 · 60").performClick();
            act.root.findViewWithTag("episode:夸克:51").performClick();
            act.root.findViewWithTag("detail-line-pill:百度").performLongClick();
            MobileBottomSheet.pickOptionContaining("删除（隐藏）此线路");
            MobileBottomSheet.confirmPending();
            check(
                    act.playCalls.isEmpty()
                            && v.lines.size() == 1
                            && "夸克".equals(v.lines.get(0).lineId())
                            && act.root.findViewWithTag("episode:夸克:51") != null
                            && btn.getText().toString().contains("播放 · 第 52 集"),
                    "R14-3b-hide-other-page: hiding non-current 百度 preserves 夸克, page 1 (51·60) & 第52集 (0 plays)");
            btn.performClick();
            check(
                    act.playCalls.size() == 1
                            && "夸克".equals(act.playCalls.get(0).line.name)
                            && "第52集".equals(act.playCalls.get(0).ep.name)
                            && act.playCalls.get(0).epNum == 52
                            && act.playCalls.get(0).resumeAt == 0,
                    "R14-3b-play: clicking main button plays 夸克 / 第52集 / 0 ms");
        }

        System.out.println("MobileDetailPrimaryButtonChecks OK (" + passed + " checks passed)");
    }
}
"""


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="mobile-detail-primary-button-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "prod-classes"
        stub_src_dir = work_dir / "stub-src"
        stub_cls_dir = work_dir / "stub-classes"
        stub_cls_dir.mkdir(parents=True, exist_ok=True)

        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[],
        )

        stub_files = []
        for rel, src in STUBS.items():
            dst = stub_src_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(src, encoding="utf-8")
            stub_files.append(str(dst))
        subprocess.run(
            [
                str(JDK / ("javac" + SUFFIX)),
                "-encoding",
                "UTF-8",
                "-source",
                "8",
                "-target",
                "8",
                "-Xlint:-options",
                "-cp",
                str(ensure_android_jar()),
                "-d",
                str(stub_cls_dir),
                *stub_files,
            ],
            check=True,
        )

        test_src_dir = work_dir / "test-src"
        test_cls_dir = work_dir / "test-classes"
        test_cls_dir.mkdir(parents=True, exist_ok=True)
        overrides = {
            "com/pilipala/marcomovie/MainActivity.java": MAIN_ACTIVITY_OVERRIDE,
            "com/pilipala/marcomovie/MobileInlinePlayer.java": MOBILE_INLINE_PLAYER_OVERRIDE,
            "com/pilipala/marcomovie/SourceController.java": SOURCE_CONTROLLER_OVERRIDE,
            "com/pilipala/marcomovie/ImmersivePoster.java": IMMERSIVE_POSTER_OVERRIDE,
            "com/pilipala/marcomovie/AiBetaGate.java": AI_BETA_GATE_OVERRIDE,
            "com/pilipala/marcomovie/MobileBottomSheet.java": MOBILE_BOTTOM_SHEET_OVERRIDE,
            "com/pilipala/marcomovie/MobileDetailPrimaryButtonChecks.java": TEST_DRIVER_JAVA,
        }
        test_files = []
        for rel, src in overrides.items():
            dst = test_src_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(src, encoding="utf-8")
            test_files.append(str(dst))
        subprocess.run(
            [
                str(JDK / ("javac" + SUFFIX)),
                "-encoding",
                "UTF-8",
                "-source",
                "8",
                "-target",
                "8",
                "-Xlint:-options",
                "-cp",
                os.pathsep.join(str(p) for p in [stub_cls_dir, *runtime_cp]),
                "-d",
                str(test_cls_dir),
                *test_files,
            ],
            check=True,
        )

        subprocess.run(
            [
                str(JDK / ("java" + SUFFIX)),
                "-Dfile.encoding=UTF-8",
                "-cp",
                os.pathsep.join(str(p) for p in [test_cls_dir, stub_cls_dir, *runtime_cp]),
                "com.pilipala.marcomovie.MobileDetailPrimaryButtonChecks",
            ],
            cwd=ROOT,
            check=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
