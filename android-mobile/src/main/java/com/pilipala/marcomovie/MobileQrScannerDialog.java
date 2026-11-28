package com.pilipala.marcomovie;

import android.Manifest;
import android.app.Dialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.graphics.SurfaceTexture;
import android.hardware.Camera;
import android.net.Uri;
import android.os.Build;
import android.view.Gravity;
import android.view.Surface;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import com.google.zxing.BarcodeFormat;
import com.google.zxing.BinaryBitmap;
import com.google.zxing.DecodeHintType;
import com.google.zxing.PlanarYUVLuminanceSource;
import com.google.zxing.RGBLuminanceSource;
import com.google.zxing.Result;
import com.google.zxing.common.HybridBinarizer;
import com.google.zxing.qrcode.QRCodeReader;
import java.io.InputStream;
import java.util.Collections;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

/**
 * In-app QR scanner dialog for Android Mobile using standard {@link Camera} + ZXing, with gallery
 * QR image picking and clipboard paste fallbacks.
 */
@SuppressWarnings("deprecation")
final class MobileQrScannerDialog {
    interface ScanCallback {
        void onQrScanned(String rawText);
    }

    interface UriCallback {
        void onUriPicked(Uri uri);
    }

    private final MainActivity a;
    private final ScanCallback callback;
    private final ExecutorService decodeExec = Executors.newSingleThreadExecutor();
    private final AtomicBoolean decoding = new AtomicBoolean(false);
    private final AtomicBoolean delivered = new AtomicBoolean(false);
    private volatile boolean closed;
    private Camera camera;
    private int cameraId = -1;
    private Dialog dialog;
    private TextureView previewView;

    private MobileQrScannerDialog(MainActivity a, ScanCallback callback) {
        this.a = a;
        this.callback = callback;
    }

    static void show(final MainActivity a, final ScanCallback callback) {
        if (a == null || a.isFinishing() || a.isDestroyed() || callback == null) return;
        a.runWithCameraPermission(() -> new MobileQrScannerDialog(a, callback).open());
    }

    static void showWithoutCameraCheck(final MainActivity a, final ScanCallback callback) {
        if (a == null || a.isFinishing() || a.isDestroyed() || callback == null) return;
        new MobileQrScannerDialog(a, callback).open();
    }

    private boolean hasCameraPermission() {
        return Build.VERSION.SDK_INT < 23
                || a.checkSelfPermission(Manifest.permission.CAMERA)
                        == PackageManager.PERMISSION_GRANTED;
    }

    private void open() {
        if (a.isFinishing() || a.isDestroyed()) return;
        final MobileTheme.Palette p = MobileTheme.of(a);
        Dialog d = new Dialog(a, android.R.style.Theme_Black_NoTitleBar_Fullscreen);
        d.requestWindowFeature(Window.FEATURE_NO_TITLE);
        this.dialog = d;

        FrameLayout root = new FrameLayout(a);
        root.setBackgroundColor(0xff0b0c10);

        previewView = new TextureView(a);
        root.addView(
                previewView,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        ViewfinderOverlay overlay = new ViewfinderOverlay(a);
        root.addView(
                overlay,
                new FrameLayout.LayoutParams(
                        ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        LinearLayout topBar = new LinearLayout(a);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(a.dp(16), a.dp(20), a.dp(16), a.dp(12));
        topBar.setBackgroundColor(0x880b0c10);

        TextView closeBtn = new TextView(a);
        closeBtn.setText("✕ 关闭");
        closeBtn.setTextColor(Color.WHITE);
        closeBtn.setTextSize(15f);
        closeBtn.setPadding(a.dp(12), a.dp(8), a.dp(12), a.dp(8));
        closeBtn.setBackground(a.bg(0x44ffffff, 18));
        closeBtn.setOnClickListener(v -> dismiss());
        topBar.addView(closeBtn);

        TextView title = new TextView(a);
        title.setText("  扫码绑定 WebDAV / 局域网同步");
        title.setTextColor(Color.WHITE);
        title.setTextSize(16f);
        topBar.addView(title, new LinearLayout.LayoutParams(0, -2, 1f));

        FrameLayout.LayoutParams topLp =
                new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, -2);
        topLp.gravity = Gravity.TOP;
        root.addView(topBar, topLp);

        LinearLayout bottomBar = new LinearLayout(a);
        bottomBar.setOrientation(LinearLayout.VERTICAL);
        bottomBar.setGravity(Gravity.CENTER_HORIZONTAL);
        bottomBar.setPadding(a.dp(18), a.dp(14), a.dp(18), a.dp(24));
        bottomBar.setBackgroundColor(0xb00b0c10);

        TextView hint = new TextView(a);
        hint.setText(
                hasCameraPermission()
                        ? "请将电视 / 电脑端「局域网接收码」或「扫码配置」二维码放入框内"
                        : "未开启相机权限：可从相册选择二维码图片或从剪贴板粘贴");
        hint.setTextColor(0xffe4e4e7);
        hint.setTextSize(13.5f);
        hint.setGravity(Gravity.CENTER);
        bottomBar.addView(hint);

        LinearLayout btnRow = new LinearLayout(a);
        btnRow.setOrientation(LinearLayout.HORIZONTAL);
        btnRow.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams rowLp = new LinearLayout.LayoutParams(-1, -2);
        rowLp.topMargin = a.dp(14);

        TextView albumBtn = pillButton("从相册选二维码", p.accent, Color.WHITE);
        albumBtn.setOnClickListener(
                v ->
                        a.pickQrImage(
                                uri -> {
                                    if (uri != null) decodeUriBitmap(uri);
                                }));
        LinearLayout.LayoutParams b1Lp = new LinearLayout.LayoutParams(0, a.dp(42), 1f);
        b1Lp.rightMargin = a.dp(10);
        btnRow.addView(albumBtn, b1Lp);

        TextView pasteBtn = pillButton("从剪贴板粘贴", 0x33ffffff, Color.WHITE);
        pasteBtn.setOnClickListener(
                v -> {
                    ClipboardManager cm =
                            (ClipboardManager) a.getSystemService(Context.CLIPBOARD_SERVICE);
                    String txt = "";
                    if (cm != null && cm.hasPrimaryClip()) {
                        ClipData clip = cm.getPrimaryClip();
                        if (clip != null
                                && clip.getItemCount() > 0
                                && clip.getItemAt(0).getText() != null) {
                            txt = clip.getItemAt(0).getText().toString().trim();
                        }
                    }
                    if (txt.isEmpty()) {
                        a.toast("剪贴板暂无内容");
                        return;
                    }
                    deliverResult(txt);
                });
        btnRow.addView(pasteBtn, new LinearLayout.LayoutParams(0, a.dp(42), 1f));
        bottomBar.addView(btnRow, rowLp);

        FrameLayout.LayoutParams botLp =
                new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, -2);
        botLp.gravity = Gravity.BOTTOM;
        root.addView(bottomBar, botLp);

        d.setContentView(root);
        d.setOnDismissListener(dialogInterface -> cleanup());

        previewView.setSurfaceTextureListener(
                new TextureView.SurfaceTextureListener() {
                    @Override
                    public void onSurfaceTextureAvailable(
                            SurfaceTexture surface, int width, int height) {
                        if (hasCameraPermission()) {
                            startCameraPreview(surface);
                        }
                    }

                    @Override
                    public void onSurfaceTextureSizeChanged(
                            SurfaceTexture surface, int width, int height) {}

                    @Override
                    public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
                        releaseCamera();
                        return true;
                    }

                    @Override
                    public void onSurfaceTextureUpdated(SurfaceTexture surface) {}
                });
        d.show();
    }

    private TextView pillButton(String label, int bgColor, int fgColor) {
        TextView btn = new TextView(a);
        btn.setText(label);
        btn.setTextColor(fgColor);
        btn.setTextSize(13.5f);
        btn.setGravity(Gravity.CENTER);
        btn.setBackground(a.bg(bgColor, 20));
        return btn;
    }

    private void startCameraPreview(SurfaceTexture surface) {
        if (closed || a.isFinishing() || a.isDestroyed()) return;
        try {
            releaseCamera();
            cameraId = findBackCameraId();
            if (cameraId < 0) {
                a.toast("当前设备未检测到可用摄像头，可改用相册或粘贴");
                return;
            }
            camera = Camera.open(cameraId);
            Camera.Parameters params = camera.getParameters();
            Camera.Size best = chooseBestPreviewSize(params.getSupportedPreviewSizes());
            if (best != null) {
                params.setPreviewSize(best.width, best.height);
            }
            List<String> focusModes = params.getSupportedFocusModes();
            if (focusModes != null) {
                if (focusModes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
                    params.setFocusMode(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE);
                } else if (focusModes.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
                    params.setFocusMode(Camera.Parameters.FOCUS_MODE_AUTO);
                }
            }
            camera.setParameters(params);
            camera.setDisplayOrientation(computeDisplayOrientation(cameraId));
            camera.setPreviewTexture(surface);
            camera.setPreviewCallback(
                    (data, cam) -> {
                        if (closed
                                || delivered.get()
                                || data == null
                                || !decoding.compareAndSet(false, true)) {
                            return;
                        }
                        final Camera.Size previewSize;
                        try {
                            previewSize = cam.getParameters().getPreviewSize();
                        } catch (Throwable err) {
                            decoding.set(false);
                            return;
                        }
                        if (previewSize == null) {
                            decoding.set(false);
                            return;
                        }
                        final byte[] frameCopy = data.clone();
                        final int w = previewSize.width;
                        final int h = previewSize.height;
                        decodeExec.execute(
                                () -> {
                                    try {
                                        if (closed || delivered.get()) return;
                                        String text = decodeYuvFrame(frameCopy, w, h);
                                        if (text != null && !text.trim().isEmpty()) {
                                            deliverResult(text.trim());
                                        }
                                    } finally {
                                        decoding.set(false);
                                    }
                                });
                    });
            camera.startPreview();
        } catch (Throwable err) {
            releaseCamera();
            a.toast("打开相机失败，请改用从相册选图或粘贴链接");
        }
    }

    private int findBackCameraId() {
        int count = Camera.getNumberOfCameras();
        int fallback = count > 0 ? 0 : -1;
        Camera.CameraInfo info = new Camera.CameraInfo();
        for (int i = 0; i < count; i++) {
            Camera.getCameraInfo(i, info);
            if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK) {
                return i;
            }
        }
        return fallback;
    }

    private int computeDisplayOrientation(int camId) {
        Camera.CameraInfo info = new Camera.CameraInfo();
        Camera.getCameraInfo(camId, info);
        int rotation = a.getWindowManager().getDefaultDisplay().getRotation();
        int degrees = 0;
        if (rotation == Surface.ROTATION_90) degrees = 90;
        else if (rotation == Surface.ROTATION_180) degrees = 180;
        else if (rotation == Surface.ROTATION_270) degrees = 270;
        if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) {
            int res = (info.orientation + degrees) % 360;
            return (360 - res) % 360;
        }
        return (info.orientation - degrees + 360) % 360;
    }

    private static Camera.Size chooseBestPreviewSize(List<Camera.Size> sizes) {
        if (sizes == null || sizes.isEmpty()) return null;
        Camera.Size best = sizes.get(0);
        int targetPixels = 1280 * 720;
        int bestDiff = Math.abs(best.width * best.height - targetPixels);
        for (Camera.Size s : sizes) {
            int pixels = s.width * s.height;
            int diff = Math.abs(pixels - targetPixels);
            if (diff < bestDiff) {
                best = s;
                bestDiff = diff;
            }
        }
        return best;
    }

    private static String decodeYuvFrame(byte[] yuv, int width, int height) {
        if (yuv == null || width <= 0 || height <= 0) return null;
        Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
        hints.put(
                DecodeHintType.POSSIBLE_FORMATS, Collections.singletonList(BarcodeFormat.QR_CODE));
        hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
        QRCodeReader reader = new QRCodeReader();
        try {
            int cropW = Math.max(240, (width * 3) / 4);
            int cropH = Math.max(240, (height * 3) / 4);
            if (cropW > width) cropW = width;
            if (cropH > height) cropH = height;
            int left = (width - cropW) / 2;
            int top = (height - cropH) / 2;
            PlanarYUVLuminanceSource cropSrc =
                    new PlanarYUVLuminanceSource(
                            yuv, width, height, left, top, cropW, cropH, false);
            Result res = reader.decode(new BinaryBitmap(new HybridBinarizer(cropSrc)), hints);
            if (res != null && res.getText() != null) return res.getText();
        } catch (Throwable ignored) {
            reader.reset();
        }
        try {
            PlanarYUVLuminanceSource fullSrc =
                    new PlanarYUVLuminanceSource(yuv, width, height, 0, 0, width, height, false);
            Result res = reader.decode(new BinaryBitmap(new HybridBinarizer(fullSrc)), hints);
            if (res != null && res.getText() != null) return res.getText();
        } catch (Throwable ignored) {
            reader.reset();
        }
        return null;
    }

    private void decodeUriBitmap(final Uri uri) {
        decodeExec.execute(
                () -> {
                    String decoded = null;
                    try {
                        BitmapFactory.Options bounds = new BitmapFactory.Options();
                        bounds.inJustDecodeBounds = true;
                        try (InputStream is = a.getContentResolver().openInputStream(uri)) {
                            if (is != null) BitmapFactory.decodeStream(is, null, bounds);
                        }
                        int sample = 1;
                        int maxDim = Math.max(bounds.outWidth, bounds.outHeight);
                        while (maxDim / sample > 1200) {
                            sample *= 2;
                        }
                        BitmapFactory.Options opts = new BitmapFactory.Options();
                        opts.inSampleSize = sample;
                        Bitmap bmp;
                        try (InputStream is = a.getContentResolver().openInputStream(uri)) {
                            bmp = is != null ? BitmapFactory.decodeStream(is, null, opts) : null;
                        }
                        if (bmp != null) {
                            int w = bmp.getWidth();
                            int h = bmp.getHeight();
                            int[] pixels = new int[w * h];
                            bmp.getPixels(pixels, 0, w, 0, 0, w, h);
                            bmp.recycle();
                            Map<DecodeHintType, Object> hints = new EnumMap<>(DecodeHintType.class);
                            hints.put(
                                    DecodeHintType.POSSIBLE_FORMATS,
                                    Collections.singletonList(BarcodeFormat.QR_CODE));
                            hints.put(DecodeHintType.TRY_HARDER, Boolean.TRUE);
                            RGBLuminanceSource src = new RGBLuminanceSource(w, h, pixels);
                            Result r =
                                    new QRCodeReader()
                                            .decode(
                                                    new BinaryBitmap(new HybridBinarizer(src)),
                                                    hints);
                            if (r != null) decoded = r.getText();
                        }
                    } catch (Throwable ignored) {
                    }
                    final String finalDecoded = decoded;
                    a.ui.post(
                            () -> {
                                if (finalDecoded != null && !finalDecoded.trim().isEmpty()) {
                                    deliverResult(finalDecoded.trim());
                                } else {
                                    a.toast("未能从所选图片识别出二维码");
                                }
                            });
                });
    }

    private void deliverResult(final String text) {
        if (!delivered.compareAndSet(false, true)) return;
        a.ui.post(
                () -> {
                    dismiss();
                    if (!a.isFinishing() && !a.isDestroyed()) {
                        callback.onQrScanned(text);
                    }
                });
    }

    private void dismiss() {
        closed = true;
        releaseCamera();
        if (dialog != null) {
            try {
                dialog.dismiss();
            } catch (Throwable ignored) {
            }
            dialog = null;
        }
    }

    private void cleanup() {
        closed = true;
        releaseCamera();
        decodeExec.shutdownNow();
    }

    private synchronized void releaseCamera() {
        if (camera != null) {
            try {
                camera.setPreviewCallback(null);
            } catch (Throwable ignored) {
            }
            try {
                camera.stopPreview();
            } catch (Throwable ignored) {
            }
            try {
                camera.release();
            } catch (Throwable ignored) {
            }
            camera = null;
        }
    }

    private static final class ViewfinderOverlay extends View {
        private final Paint maskPaint = new Paint();
        private final Paint cornerPaint = new Paint(Paint.ANTI_ALIAS_FLAG);

        ViewfinderOverlay(Context context) {
            super(context);
            maskPaint.setColor(0x66000000);
            cornerPaint.setColor(0xff5ac8fa);
            cornerPaint.setStrokeWidth(context.getResources().getDisplayMetrics().density * 3.5f);
            cornerPaint.setStyle(Paint.Style.STROKE);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            int w = getWidth();
            int h = getHeight();
            float size = Math.min(w, h) * 0.64f;
            float left = (w - size) / 2f;
            float top = (h - size) * 0.44f;
            float right = left + size;
            float bottom = top + size;
            canvas.drawRect(0, 0, w, top, maskPaint);
            canvas.drawRect(0, top, left, bottom, maskPaint);
            canvas.drawRect(right, top, w, bottom, maskPaint);
            canvas.drawRect(0, bottom, w, h, maskPaint);

            float arm = size * 0.12f;
            RectF r = new RectF(left, top, right, bottom);
            canvas.drawLine(r.left, r.top, r.left + arm, r.top, cornerPaint);
            canvas.drawLine(r.left, r.top, r.left, r.top + arm, cornerPaint);
            canvas.drawLine(r.right - arm, r.top, r.right, r.top, cornerPaint);
            canvas.drawLine(r.right, r.top, r.right, r.top + arm, cornerPaint);
            canvas.drawLine(r.left, r.bottom - arm, r.left, r.bottom, cornerPaint);
            canvas.drawLine(r.left, r.bottom, r.left + arm, r.bottom, cornerPaint);
            canvas.drawLine(r.right - arm, r.bottom, r.right, r.bottom, cornerPaint);
            canvas.drawLine(r.right, r.bottom - arm, r.right, r.bottom, cornerPaint);
        }
    }
}
