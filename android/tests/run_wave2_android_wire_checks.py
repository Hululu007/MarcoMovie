"""Compile real Android Java sources and run Wave 2 Android wiring regression checks."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, ensure_android_jar, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

EXTRA_RUNTIME_STUBS = {
    "android/util/DisplayMetrics.java": """package android.util;

public class DisplayMetrics {
    public float density = 2.0f;
    public float scaledDensity = 2.0f;
    public int widthPixels = 1080;
    public int heightPixels = 1920;
    public int densityDpi = 320;
}
""",
    "android/content/res/Resources.java": """package android.content.res;

import android.util.DisplayMetrics;

public class Resources {
    private final DisplayMetrics metrics = new DisplayMetrics();

    public DisplayMetrics getDisplayMetrics() {
        return metrics;
    }
}
""",
    "android/content/Context.java": """package android.content;

import android.content.res.Resources;

public class Context {
    private final Resources resources = new Resources();

    public Resources getResources() {
        return resources;
    }

    public Context getApplicationContext() {
        return this;
    }
}
""",
    "android/view/ViewParent.java": """package android.view;

public interface ViewParent {}
""",
    "android/view/View.java": """package android.view;

import android.content.Context;
import android.content.res.Resources;
import java.util.ArrayList;
import java.util.List;

public class View {
    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;
    public static final int LAYER_TYPE_NONE = 0;
    public static final int LAYER_TYPE_SOFTWARE = 1;
    public static final int LAYER_TYPE_HARDWARE = 2;

    public interface OnAttachStateChangeListener {
        void onViewAttachedToWindow(View v);

        void onViewDetachedFromWindow(View v);
    }

    private final Context context;
    ViewParent parent;
    private Object tag;
    private int layerType = LAYER_TYPE_NONE;
    private float scaleX = 1f;
    private float scaleY = 1f;
    private float translationX = 0f;
    private float translationY = 0f;
    private float alpha = 1f;
    private final List<OnAttachStateChangeListener> attachListeners = new ArrayList<>();

    public View(Context context) {
        this.context = context != null ? context : new Context();
    }

    public Context getContext() {
        return context;
    }

    public Resources getResources() {
        return context.getResources();
    }

    public ViewParent getParent() {
        return parent;
    }

    public void setTag(Object tag) {
        this.tag = tag;
    }

    public Object getTag() {
        return tag;
    }

    public void setLayerType(int layerType, android.graphics.Paint paint) {
        this.layerType = layerType;
    }

    public int getLayerType() {
        return layerType;
    }

    public void setScaleX(float v) {
        this.scaleX = v;
    }

    public float getScaleX() {
        return scaleX;
    }

    public void setScaleY(float v) {
        this.scaleY = v;
    }

    public float getScaleY() {
        return scaleY;
    }

    public void setTranslationX(float v) {
        this.translationX = v;
    }

    public float getTranslationX() {
        return translationX;
    }

    public void setTranslationY(float v) {
        this.translationY = v;
    }

    public float getTranslationY() {
        return translationY;
    }

    public void setAlpha(float v) {
        this.alpha = v;
    }

    public float getAlpha() {
        return alpha;
    }

    public void addOnAttachStateChangeListener(OnAttachStateChangeListener l) {
        if (l != null && !attachListeners.contains(l)) {
            attachListeners.add(l);
        }
    }

    public void removeOnAttachStateChangeListener(OnAttachStateChangeListener l) {
        attachListeners.remove(l);
    }

    public int getAttachListenerCount() {
        return attachListeners.size();
    }

    public void dispatchDetachedFromWindow() {
        for (OnAttachStateChangeListener l : new ArrayList<>(attachListeners)) {
            l.onViewDetachedFromWindow(this);
        }
    }
}
""",
    "android/view/ViewGroup.java": """package android.view;

import android.content.Context;
import java.util.ArrayList;
import java.util.List;

public class ViewGroup extends View implements ViewParent {
    public static class LayoutParams {
        public static final int MATCH_PARENT = -1;
        public static final int WRAP_CONTENT = -2;
        public int width;
        public int height;

        public LayoutParams(int width, int height) {
            this.width = width;
            this.height = height;
        }
    }

    private final List<View> children = new ArrayList<>();

    public ViewGroup(Context context) {
        super(context);
    }

    public int getChildCount() {
        return children.size();
    }

    public View getChildAt(int index) {
        return children.get(index);
    }

    public int indexOfChild(View child) {
        return children.indexOf(child);
    }

    public void addView(View child) {
        addView(child, children.size(), null);
    }

    public void addView(View child, LayoutParams params) {
        addView(child, children.size(), params);
    }

    public void addView(View child, int index) {
        addView(child, index, null);
    }

    public void addView(View child, int index, LayoutParams params) {
        if (child.parent != null) {
            throw new IllegalStateException("Child already has a parent");
        }
        if (index < 0 || index > children.size()) {
            children.add(child);
        } else {
            children.add(index, child);
        }
        child.parent = this;
    }

    public void removeView(View child) {
        if (children.remove(child)) {
            child.parent = null;
        }
    }
}
""",
    "android/widget/FrameLayout.java": """package android.widget;

import android.content.Context;
import android.view.ViewGroup;

public class FrameLayout extends ViewGroup {
    public static class LayoutParams extends ViewGroup.LayoutParams {
        public int gravity;
        public int leftMargin;
        public int topMargin;
        public int rightMargin;
        public int bottomMargin;

        public LayoutParams(int width, int height) {
            super(width, height);
        }

        public LayoutParams(int width, int height, int gravity) {
            super(width, height);
            this.gravity = gravity;
        }
    }

    public FrameLayout(Context context) {
        super(context);
    }
}
""",
    "android/view/animation/Interpolator.java": """package android.view.animation;

import android.animation.TimeInterpolator;

public interface Interpolator extends TimeInterpolator {}
""",
    "android/animation/TimeInterpolator.java": """package android.animation;

public interface TimeInterpolator {
    float getInterpolation(float input);
}
""",
    "android/view/animation/LinearInterpolator.java": """package android.view.animation;

public class LinearInterpolator implements Interpolator {
    @Override
    public float getInterpolation(float input) {
        return input;
    }
}
""",
    "android/view/animation/PathInterpolator.java": """package android.view.animation;

public class PathInterpolator implements Interpolator {
    public PathInterpolator(float x1, float y1, float x2, float y2) {}

    @Override
    public float getInterpolation(float input) {
        return input;
    }
}
""",
    "android/animation/Animator.java": """package android.animation;

import java.util.ArrayList;
import java.util.List;

public abstract class Animator {
    public interface AnimatorListener {
        void onAnimationStart(Animator animation);

        void onAnimationEnd(Animator animation);

        void onAnimationCancel(Animator animation);

        void onAnimationRepeat(Animator animation);
    }

    protected final List<AnimatorListener> listeners = new ArrayList<>();

    public void addListener(AnimatorListener listener) {
        if (listener != null) listeners.add(listener);
    }

    public void removeAllListeners() {
        listeners.clear();
    }

    public abstract void start();

    public abstract void cancel();

    public abstract boolean isRunning();

    public abstract boolean isStarted();
}
""",
    "android/animation/AnimatorListenerAdapter.java": """package android.animation;

public abstract class AnimatorListenerAdapter implements Animator.AnimatorListener {
    @Override
    public void onAnimationStart(Animator animation) {}

    @Override
    public void onAnimationEnd(Animator animation) {}

    @Override
    public void onAnimationCancel(Animator animation) {}

    @Override
    public void onAnimationRepeat(Animator animation) {}
}
""",
    "android/animation/ValueAnimator.java": """package android.animation;

import java.util.ArrayList;
import java.util.List;

public class ValueAnimator extends Animator {
    public interface AnimatorUpdateListener {
        void onAnimationUpdate(ValueAnimator animation);
    }

    private static ValueAnimator lastStarted;
    private final float startVal;
    private final float endVal;
    private float currentVal;
    private long duration;
    private TimeInterpolator interpolator;
    private boolean started;
    private boolean running;
    private final List<AnimatorUpdateListener> updateListeners = new ArrayList<>();

    private ValueAnimator(float startVal, float endVal) {
        this.startVal = startVal;
        this.endVal = endVal;
        this.currentVal = startVal;
    }

    public static ValueAnimator ofFloat(float... values) {
        float s = values.length > 0 ? values[0] : 0f;
        float e = values.length > 1 ? values[values.length - 1] : s;
        return new ValueAnimator(s, e);
    }

    public static void clearLastStarted() {
        lastStarted = null;
    }

    public static ValueAnimator getLastStarted() {
        return lastStarted;
    }

    public ValueAnimator setDuration(long duration) {
        this.duration = duration;
        return this;
    }

    public long getDuration() {
        return duration;
    }

    public void setInterpolator(TimeInterpolator value) {
        this.interpolator = value;
    }

    public void addUpdateListener(AnimatorUpdateListener listener) {
        if (listener != null) updateListeners.add(listener);
    }

    public void removeAllUpdateListeners() {
        updateListeners.clear();
    }

    public Object getAnimatedValue() {
        return Float.valueOf(currentVal);
    }

    @Override
    public void start() {
        started = true;
        running = true;
        lastStarted = this;
        for (AnimatorListener l : new ArrayList<>(listeners)) {
            l.onAnimationStart(this);
        }
    }

    public void stepTo(float fraction) {
        float t = interpolator != null ? interpolator.getInterpolation(fraction) : fraction;
        currentVal = startVal + (endVal - startVal) * t;
        for (AnimatorUpdateListener l : new ArrayList<>(updateListeners)) {
            l.onAnimationUpdate(this);
        }
    }

    public void finish() {
        if (!running) return;
        stepTo(1f);
        running = false;
        started = false;
        for (AnimatorListener l : new ArrayList<>(listeners)) {
            l.onAnimationEnd(this);
        }
    }

    @Override
    public void cancel() {
        if (!started && !running) return;
        running = false;
        started = false;
        for (AnimatorListener l : new ArrayList<>(listeners)) {
            l.onAnimationCancel(this);
        }
    }

    @Override
    public boolean isRunning() {
        return running;
    }

    @Override
    public boolean isStarted() {
        return started;
    }
}
""",
}


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="wave2-android-wire-checks-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"
        extra_src_dir = work_dir / "extra-stubs-src"
        extra_cls_dir = work_dir / "extra-stubs-classes"
        extra_cls_dir.mkdir(parents=True, exist_ok=True)

        extra_files = []
        for rel, src in EXTRA_RUNTIME_STUBS.items():
            dst = extra_src_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(src, encoding="utf-8")
            extra_files.append(str(dst))

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
                str(extra_cls_dir),
                *extra_files,
            ],
            check=True,
        )

        # Compile real Android sources against real android.jar + dep jars, and compile the test
        # against both real compiled Android classes and our runtime stubs (for stub helper methods
        # like ValueAnimator.stepTo/finish and View.dispatchDetachedFromWindow).
        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[],
        )
        test_cls_dir = work_dir / "test-classes"
        test_cls_dir.mkdir(parents=True, exist_ok=True)
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
                os.pathsep.join(str(p) for p in [extra_cls_dir, *runtime_cp]),
                "-d",
                str(test_cls_dir),
                str(ROOT / "android/tests/Wave2AndroidWireChecks.java"),
            ],
            check=True,
        )
        subprocess.run(
            [
                str(JDK / ("java" + SUFFIX)),
                "-Dfile.encoding=UTF-8",
                "-cp",
                os.pathsep.join(str(p) for p in [test_cls_dir, extra_cls_dir, *runtime_cp]),
                "com.pilipala.marcomovie.Wave2AndroidWireChecks",
                str(ROOT),
            ],
            cwd=ROOT,
            check=True,
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
