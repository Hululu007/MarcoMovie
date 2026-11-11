package com.pilipala.marcomovie;

import android.graphics.*;
import android.view.*;

/** One continuous glass lens follows selection; buttons never cross-fade their backgrounds. */
final class GlassSelection {
    final MainActivity a;
    final ViewGroup owner;
    final float cornerDp;
    final boolean subtle;
    final MotionSpring left = new MotionSpring(0, 38, .25f),
            top = new MotionSpring(0, 38, .25f),
            right = new MotionSpring(0, 38, .25f),
            bottom = new MotionSpring(0, 38, .25f);
    final RectF bounds = new RectF(), drawing = new RectF();
    final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    final Matrix shaderMatrix = new Matrix();
    final LinearGradient fillShader;
    final LinearGradient strokeShader;
    View target;
    MotionLoop.Step animator;
    boolean positioned;

    GlassSelection(MainActivity activity, ViewGroup parent) {
        this(activity, parent, -1f, false);
    }

    GlassSelection(MainActivity activity, ViewGroup parent, float cornerDp, boolean subtle) {
        a = activity;
        owner = parent;
        this.cornerDp = cornerDp;
        this.subtle = subtle;
        fillShader =
                subtle
                        ? new LinearGradient(
                                0,
                                0,
                                1,
                                1,
                                new int[] {0x2affffff, 0x16ffffff, 0x1effffff},
                                new float[] {0, .55f, 1},
                                Shader.TileMode.CLAMP)
                        : new LinearGradient(
                                0,
                                0,
                                1,
                                1,
                                new int[] {0x65ffffff, 0x239bb7de, 0x3aacc5ed},
                                new float[] {0, .52f, 1},
                                Shader.TileMode.CLAMP);
        strokeShader =
                subtle
                        ? new LinearGradient(
                                0,
                                0,
                                1,
                                1,
                                new int[] {0x54ffffff, 0x1effffff, 0x32ffffff},
                                null,
                                Shader.TileMode.CLAMP)
                        : new LinearGradient(
                                0,
                                0,
                                1,
                                1,
                                new int[] {0xeeffffff, 0x3888bbef, 0x9bd5e5ff},
                                null,
                                Shader.TileMode.CLAMP);
        owner.addOnAttachStateChangeListener(
                new View.OnAttachStateChangeListener() {
                    public void onViewAttachedToWindow(View view) {
                        refresh();
                    }

                    public void onViewDetachedFromWindow(View view) {
                        stop();
                    }
                });
    }

    void select(View view) {
        target = view;
        refresh();
    }

    void stop() {
        if (animator != null) MotionLoop.remove(animator);
        animator = null;
    }

    void refresh() {
        if (target == null || target.getParent() != owner || target.getWidth() == 0) return;
        float inset = a.dp(1);
        float l = target.getLeft() + inset,
                t = target.getTop() + inset,
                r = target.getRight() - inset,
                b = target.getBottom() - inset;
        if (!positioned || a.reduced || !owner.isAttachedToWindow()) {
            stop();
            left.snap(l);
            top.snap(t);
            right.snap(r);
            bottom.snap(b);
            positioned = true;
        } else {
            left.target(l);
            top.target(t);
            right.target(r);
            bottom.target(b);
            if (animator == null
                    && (left.step(0) || top.step(0) || right.step(0) || bottom.step(0))) {
                animator =
                        seconds -> {
                            if (!owner.isAttachedToWindow()) {
                                animator = null;
                                return false;
                            }
                            boolean moving = left.step(seconds);
                            moving |= top.step(seconds);
                            moving |= right.step(seconds);
                            moving |= bottom.step(seconds);
                            owner.invalidate();
                            if (!moving) animator = null;
                            return moving;
                        };
                MotionLoop.add(animator);
            }
        }
        owner.invalidate();
    }

    void draw(Canvas canvas) {
        if (!positioned || target == null || target.getParent() != owner) return;
        bounds.set(left.value, top.value, right.value, bottom.value);
        drawing.set(bounds);
        if (!subtle) {
            // A small stretch preserves the impression of one deforming lens on fast reversals.
            float stretchX = Math.min(a.dp(7), Math.abs(left.velocity + right.velocity) * .00065f);
            float stretchY = Math.min(a.dp(4), Math.abs(top.velocity + bottom.velocity) * .00065f);
            drawing.inset(-stretchX, -stretchY);
        }
        float maxRadius = Math.min(drawing.width(), drawing.height()) * .5f;
        float radius = cornerDp > 0 ? Math.min(a.dp(cornerDp), maxRadius) : maxRadius;
        float w = Math.max(1f, drawing.width()), h = Math.max(1f, drawing.height());
        shaderMatrix.setScale(w, h);
        shaderMatrix.postTranslate(drawing.left, drawing.top);
        fillShader.setLocalMatrix(shaderMatrix);
        strokeShader.setLocalMatrix(shaderMatrix);
        paint.setAlpha(255);
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(fillShader);
        canvas.drawRoundRect(drawing, radius, radius, paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(Math.max(1, a.dp(subtle ? 1f : 1.1f)));
        paint.setShader(strokeShader);
        canvas.drawRoundRect(drawing, radius, radius, paint);
        paint.setShader(null);
        if (!subtle) {
            paint.setStrokeWidth(Math.max(1, a.dp(.65f)));
            paint.setColor(0x25ffffff);
            drawing.inset(a.dp(2), a.dp(2));
            canvas.drawRoundRect(drawing, radius, radius, paint);
        }
    }
}
