"""Behavioral regression suite for Android Mobile 0.7.0 Codex review items #1-#12."""

from pathlib import Path
import io
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(ROOT / 'scripts'))

from android_compile_support import SUFFIX, compile_real_android_sources, ensure_android_jar, resolve_jdk_bin
import build_python_android
from build_android_mobile import (
    URLLIB3_DEP_ARCHIVE,
    URLLIB3_DEP_SHA256,
    URLLIB3_DEP_URL,
    normalize_mobile_python_pure_deps,
    verify_mobile_delivery_bundle,
    verify_mobile_python_apk,
)

JDK = resolve_jdk_bin()

EXTRA_RUNTIME_STUBS = {
    'dalvik/system/BaseDexClassLoader.java': """package dalvik.system;

import java.io.File;

public class BaseDexClassLoader extends ClassLoader {
    public BaseDexClassLoader(
            String dexPath, File optimizedDirectory, String librarySearchPath, ClassLoader parent) {
        super(parent);
    }
}
""",
    'android/app/Application.java': """package android.app;

import android.content.ContextWrapper;
import android.os.Bundle;
import java.util.ArrayList;

public class Application extends ContextWrapper {
    public interface ActivityLifecycleCallbacks {
        void onActivityCreated(Activity activity, Bundle savedInstanceState);
        void onActivityStarted(Activity activity);
        void onActivityResumed(Activity activity);
        void onActivityPaused(Activity activity);
        void onActivityStopped(Activity activity);
        void onActivitySaveInstanceState(Activity activity, Bundle outState);
        void onActivityDestroyed(Activity activity);
    }

    private final ArrayList<ActivityLifecycleCallbacks> mActivityLifecycleCallbacks =
            new ArrayList<>();

    public Application() {
        super(null);
    }

    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        synchronized (mActivityLifecycleCallbacks) {
            mActivityLifecycleCallbacks.add(callback);
        }
    }

    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        synchronized (mActivityLifecycleCallbacks) {
            mActivityLifecycleCallbacks.remove(callback);
        }
    }
}
""",
    'android/os/Bundle.java': """package android.os;

public final class Bundle {}
""",
    'android/content/ContextWrapper.java': """package android.content;

public class ContextWrapper extends Context {
    private Context mBase;

    public ContextWrapper(Context base) {
        mBase = base;
    }

    protected void attachBaseContext(Context base) {
        mBase = base;
    }

    public Context getBaseContext() {
        return mBase;
    }
}
""",
    'android/content/Context.java': """package android.content;

public abstract class Context {}
""",
    'android/app/Activity.java': """package android.app;

import android.content.ContextWrapper;

public class Activity extends ContextWrapper {
    Application mApplication;
    boolean mFinishing;
    boolean mDestroyed;

    public Activity() {
        super(null);
    }

    public final Application getApplication() {
        return mApplication;
    }

    public boolean isFinishing() {
        return mFinishing;
    }

    public boolean isDestroyed() {
        return mDestroyed;
    }
}
""",
    'android/view/View.java': """package android.view;

import android.content.Context;

public class View {
    public interface OnClickListener {
        void onClick(View v);
    }

    private boolean enabled = true;
    private boolean clickable = true;
    private float alpha = 1.0f;
    private OnClickListener clickListener;

    public View(Context context) {}

    public void setEnabled(boolean enabled) {
        this.enabled = enabled;
    }

    public boolean isEnabled() {
        return enabled;
    }

    public void setClickable(boolean clickable) {
        this.clickable = clickable;
    }

    public boolean isClickable() {
        return clickable;
    }

    public void setAlpha(float alpha) {
        this.alpha = alpha;
    }

    public float getAlpha() {
        return alpha;
    }

    public void setOnClickListener(OnClickListener l) {
        this.clickListener = l;
    }

    public boolean performClick() {
        if (clickListener != null) {
            clickListener.onClick(this);
            return true;
        }
        return false;
    }
}
""",
}


def _compile_plugin_fixture_classes(work_dir: Path) -> Path:
    """Compile isolated spider Init + ActivityLifecycleCallbacks fixtures off the app classpath."""
    src_dir = work_dir / 'plugin-fixture-src/com/github/catvod/spider'
    cls_dir = work_dir / 'plugin-fixture-classes'
    src_dir.mkdir(parents=True, exist_ok=True)
    cls_dir.mkdir(parents=True, exist_ok=True)
    init_java = src_dir / 'Init.java'
    init_java.write_text(
        """package com.github.catvod.spider;

import android.app.Activity;
import java.util.concurrent.atomic.AtomicInteger;

public class Init {
    public static final AtomicInteger SET_ACTIVITY_CALLS = new AtomicInteger();
    public static volatile Activity lastActivity;

    public static void setActivity(Activity a) {
        SET_ACTIVITY_CALLS.incrementAndGet();
        lastActivity = a;
    }
}
""",
        encoding='utf-8',
    )
    cb_java = src_dir / 'PluginCallback.java'
    cb_java.write_text(
        """package com.github.catvod.spider;

import android.app.Activity;
import android.app.Application;
import android.os.Bundle;

public class PluginCallback implements Application.ActivityLifecycleCallbacks {
    @Override public void onActivityCreated(Activity a, Bundle b) {}
    @Override public void onActivityStarted(Activity a) {}
    @Override public void onActivityResumed(Activity a) {}
    @Override public void onActivityPaused(Activity a) {}
    @Override public void onActivityStopped(Activity a) {}
    @Override public void onActivitySaveInstanceState(Activity a, Bundle b) {}
    @Override public void onActivityDestroyed(Activity a) {}
}
""",
        encoding='utf-8',
    )
    subprocess.run(
        [
            str(JDK / ('javac' + SUFFIX)),
            '-encoding',
            'UTF-8',
            '-source',
            '8',
            '-target',
            '8',
            '-Xlint:-options',
            '-cp',
            str(ensure_android_jar()),
            '-d',
            str(cls_dir),
            str(init_java),
            str(cb_java),
        ],
        check=True,
    )
    return cls_dir


def verify_urllib3_url_normalization():
    """Test R3: normalize_mobile_python_pure_deps repairs 6e173b7's broken v2.2.3 URL while keeping SHA-256."""
    snapshot = list(build_python_android.PURE_DEPS)
    try:
        broken = []
        for entry in snapshot:
            filename, url, digest, src_prefix, dst_prefix = entry
            if filename == URLLIB3_DEP_ARCHIVE:
                url = 'https://github.com/urllib3/urllib3/archive/refs/tags/v2.2.3.zip'
            broken.append((filename, url, digest, src_prefix, dst_prefix))
        build_python_android.PURE_DEPS[:] = broken
        normalize_mobile_python_pure_deps()
        matched = [e for e in build_python_android.PURE_DEPS if e[0] == URLLIB3_DEP_ARCHIVE]
        if len(matched) != 1 or matched[0][1] != URLLIB3_DEP_URL or matched[0][2] != URLLIB3_DEP_SHA256:
            raise AssertionError(f'Unexpected normalized urllib3 entry: {matched}')
        print('PASS #3 normalize_mobile_python_pure_deps repairs v2.2.3 -> 2.2.3 with exact SHA-256')
    finally:
        build_python_android.PURE_DEPS[:] = snapshot


def _repack_apk(src_apk: Path, dst_apk: Path, mutate):
    with zipfile.ZipFile(src_apk) as src, zipfile.ZipFile(dst_apk, 'w', zipfile.ZIP_DEFLATED) as dst:
        for info in src.infolist():
            data = src.read(info.filename)
            replacement = mutate(info.filename, data)
            if replacement is None:
                continue
            dst.writestr(info.filename, replacement)


def _corrupt_elf64_align_to_4k(elf_bytes: bytes) -> bytes:
    """Patch all PT_LOAD p_align entries in a 64-bit little-endian ELF from 16 KB to 4 KB."""
    buf = bytearray(elf_bytes)
    e_phoff = struct.unpack_from('<Q', buf, 32)[0]
    e_phentsize = struct.unpack_from('<H', buf, 54)[0]
    e_phnum = struct.unpack_from('<H', buf, 56)[0]
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from('<I', buf, off)[0]
        if p_type == 1:  # PT_LOAD
            struct.pack_into('<Q', buf, off + 48, 4096)
    return bytes(buf)


def verify_apk_python_mutants(apk: Path):
    """Test item #12: valid APK passes; missing dynload, swapped ABIs, and bad arm64 alignment fail."""
    verify_mobile_python_apk(apk)
    print('PASS #12 verifier accepts real built Mobile APK (both ABIs + all dynload extensions)')

    with tempfile.TemporaryDirectory(prefix='mobile-py-verify-mutants-') as tmp:
        tmp_dir = Path(tmp)

        # Mutant 1: remove arm64 dynload zip completely
        missing_apk = tmp_dir / 'missing-dynload.apk'
        _repack_apk(
            apk,
            missing_apk,
            lambda name, data: None if name == 'assets/python-native/lib-dynload-arm64-v8a.zip' else data,
        )
        try:
            verify_mobile_python_apk(missing_apk)
            raise AssertionError('Expected missing dynload zip to fail verify_mobile_python_apk')
        except ValueError:
            print('PASS #12 verifier rejects APK with missing lib-dynload-arm64-v8a.zip')

        # Mutant 2: swap armeabi-v7a and arm64-v8a dynload zips
        with zipfile.ZipFile(apk) as src:
            dyn32 = src.read('assets/python-native/lib-dynload-armeabi-v7a.zip')
            dyn64 = src.read('assets/python-native/lib-dynload-arm64-v8a.zip')
        swapped_apk = tmp_dir / 'swapped-dynload.apk'
        def _swap(name, data):
            if name == 'assets/python-native/lib-dynload-armeabi-v7a.zip':
                return dyn64
            if name == 'assets/python-native/lib-dynload-arm64-v8a.zip':
                return dyn32
            return data
        _repack_apk(apk, swapped_apk, _swap)
        try:
            verify_mobile_python_apk(swapped_apk)
            raise AssertionError('Expected swapped dynload ABIs to fail verify_mobile_python_apk')
        except ValueError:
            print('PASS #12 verifier rejects APK with swapped armeabi-v7a/arm64-v8a dynload zips')

        # Mutant 3: corrupt single arm64 extension (_ssl.cpython-311.so) to 4 KB alignment
        bad_dyn64_buf = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(dyn64)) as z_in, zipfile.ZipFile(
            bad_dyn64_buf, 'w', zipfile.ZIP_DEFLATED
        ) as z_out:
            for item in z_in.infolist():
                raw = z_in.read(item.filename)
                if item.filename == '_ssl.cpython-311.so':
                    raw = _corrupt_elf64_align_to_4k(raw)
                z_out.writestr(item.filename, raw)
        bad_align_apk = tmp_dir / 'bad-arm64-ext-align.apk'
        _repack_apk(
            apk,
            bad_align_apk,
            lambda name, data: bad_dyn64_buf.getvalue()
            if name == 'assets/python-native/lib-dynload-arm64-v8a.zip'
            else data,
        )
        try:
            verify_mobile_python_apk(bad_align_apk)
            raise AssertionError('Expected 4 KB aligned arm64 _ssl extension to fail verify_mobile_python_apk')
        except ValueError:
            print('PASS #12 verifier rejects APK with single arm64 _ssl extension misaligned to 4 KB')


def verify_apk_dex_no_put_if_absent(apk: Path):
    """Test item #1: verify final APK DEX has zero putIfAbsent calls in Cms."""
    from android_build_common import SDK, exe
    dexdump = exe(SDK, 'dexdump')
    with tempfile.TemporaryDirectory(prefix='mobile-dex-check-') as tmp:
        tmp_dir = Path(tmp)
        with zipfile.ZipFile(apk) as z:
            dex_names = [n for n in z.namelist() if n.endswith('.dex')]
            found_cms = False
            for dex_name in dex_names:
                dex_path = tmp_dir / dex_name
                dex_path.write_bytes(z.read(dex_name))
                dump = subprocess.check_output(
                    [str(dexdump), '-d', str(dex_path)], text=True, errors='replace'
                )
                marker = "Class descriptor  : 'Lcom/pilipala/marcomovie/Cms;'"
                idx = dump.find(marker)
                if idx >= 0:
                    found_cms = True
                    next_cls = dump.find('Class descriptor  :', idx + len(marker))
                    cms_section = dump[idx:] if next_cls < 0 else dump[idx:next_cls]
                    if 'putIfAbsent' in cms_section:
                        raise AssertionError(
                            f'Found API 24+ putIfAbsent call inside Cms in {dex_name}!'
                        )
            if not found_cms:
                raise AssertionError('Did not find Lcom/pilipala/marcomovie/Cms; in APK DEX files')
    print('PASS #1 final APK DEX contains zero putIfAbsent calls in Cms (API 23 safe)')


def verify_apk_idsig_delivery_checks(apk: Path):
    """Test P2-1: delivery verifier passes matching .idsig (v4=true) and rejects old/missing .idsig."""
    from android_build_common import ENV, JDK as BUILD_JDK, SDK, exe

    alias_apk = apk.with_name('MarcoMovie-0.7.0-mobile.apk')
    idsig = apk.with_name(apk.name + '.idsig')

    # Case 1: Matching bundle (.apk + alias + .sha256 + matching .idsig) -> PASS with v4=true
    sig_text, signer_sha, digest = verify_mobile_delivery_bundle(apk, alias_apk, idsig=idsig)
    if 'Verified using v4 scheme (APK Signature Scheme v4): true' not in sig_text:
        raise AssertionError('Expected matching .idsig verification to report v4=true')
    sig_record = ROOT / 'android-mobile/build/apk-signature.txt'
    if sig_record.is_file():
        saved_sig = sig_record.read_text(encoding='utf-8')
        if 'Verified using v4 scheme (APK Signature Scheme v4): true' not in saved_sig:
            raise AssertionError('Expected android-mobile/build/apk-signature.txt to record v4=true')
    print(f'PASS P2-1 Case 1 matching .idsig passes delivery check (v1/v2/v3/v4=true, sha256={digest[:12]}...)')

    with tempfile.TemporaryDirectory(prefix='mobile-idsig-check-') as tmp:
        tmp_dir = Path(tmp)

        # Case 2: Genuine .idsig generated with an ephemeral self-signed test key for a DIFFERENT
        # (simulated old) APK -> works even without project private key, and MUST FAIL even when
        # raw apksigner exits 0 with v4=false!
        other_unsigned = tmp_dir / 'other-old.unsigned.apk'
        with zipfile.ZipFile(other_unsigned, 'w', zipfile.ZIP_DEFLATED) as z:
            z.writestr('AndroidManifest.xml', b'dummy-old-manifest-payload')
        other_signed = tmp_dir / 'other-old.apk'
        ephemeral_key = tmp_dir / 'ephemeral-test.p12'
        ephemeral_env = dict(ENV, MARCOMOVIE_TEST_KEY_PASS='testpass')
        subprocess.run(
            [
                str(exe(BUILD_JDK / 'bin', 'keytool')),
                '-genkeypair',
                '-keystore',
                str(ephemeral_key),
                '-storetype',
                'PKCS12',
                '-alias',
                'testkey',
                '-storepass:env',
                'MARCOMOVIE_TEST_KEY_PASS',
                '-keypass:env',
                'MARCOMOVIE_TEST_KEY_PASS',
                '-keyalg',
                'RSA',
                '-keysize',
                '2048',
                '-validity',
                '1',
                '-dname',
                'CN=TestOnly',
            ],
            cwd=ROOT,
            env=ephemeral_env,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            [
                str(exe(BUILD_JDK / 'bin', 'java')),
                '-jar',
                str(SDK / 'lib/apksigner.jar'),
                'sign',
                '--min-sdk-version',
                '23',
                '--ks',
                str(ephemeral_key),
                '--ks-key-alias',
                'testkey',
                '--ks-pass',
                'env:MARCOMOVIE_TEST_KEY_PASS',
                '--out',
                str(other_signed),
                str(other_unsigned),
            ],
            cwd=ROOT,
            env=ephemeral_env,
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        mismatched_idsig = other_signed.with_name(other_signed.name + '.idsig')
        if not mismatched_idsig.is_file():
            raise AssertionError('Expected apksigner sign to emit mismatched test .idsig')
        try:
            verify_mobile_delivery_bundle(apk, alias_apk, idsig=mismatched_idsig)
            raise AssertionError('Expected old/mismatched .idsig to fail verify_mobile_delivery_bundle')
        except RuntimeError as expected_err:
            if 'v4 scheme' not in str(expected_err):
                raise AssertionError(f'Unexpected error for mismatched .idsig: {expected_err}')
            print('PASS P2-1 Case 2 mismatched old APK .idsig rejected (v4=false caught despite exit 0)')

        # Case 3: Missing .idsig -> MUST FAIL
        missing_idsig = tmp_dir / 'nonexistent.apk.idsig'
        try:
            verify_mobile_delivery_bundle(apk, alias_apk, idsig=missing_idsig)
            raise AssertionError('Expected missing .idsig to fail verify_mobile_delivery_bundle')
        except RuntimeError as expected_err:
            if 'Missing required APK v4 signature file' not in str(expected_err):
                raise AssertionError(f'Unexpected error for missing .idsig: {expected_err}')
            print('PASS P2-1 Case 3 missing .idsig rejected explicitly')


def main():
    verify_urllib3_url_normalization()
    with tempfile.TemporaryDirectory(prefix='mobile-codex-review-checks-') as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / 'classes'
        fixture_dir = _compile_plugin_fixture_classes(work_dir)
        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[ROOT / 'android-mobile/tests/MobileCodexReviewChecks.java'],
            extra_runtime_stubs=EXTRA_RUNTIME_STUBS,
        )
        run_cp = os.pathsep.join(str(p) for p in runtime_cp)
        subprocess.run(
            [
                str(JDK / ('java' + SUFFIX)),
                '-Dfile.encoding=UTF-8',
                f'-Dtest.plugin.fixture.dir={fixture_dir}',
                '-cp',
                run_cp,
                'com.pilipala.marcomovie.MobileCodexReviewChecks',
            ],
            cwd=ROOT,
            check=True,
        )

    apk = ROOT / 'dist/MarcoMovie-0.7.0-android-mobile.apk'
    if '--verify-apk' in sys.argv:
        if not apk.is_file():
            raise FileNotFoundError(f'Missing built Mobile APK: {apk}')
        verify_apk_dex_no_put_if_absent(apk)
        verify_apk_python_mutants(apk)
        verify_apk_idsig_delivery_checks(apk)


if __name__ == '__main__':
    main()
