"""Build a separate instrumentation APK using the local development identity."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import sys
import wave
import zipfile

sys.path.insert(0, str(Path(__file__).parent))
from android_build_common import ANDROID, JDK, ROOT, SDK, exe, resolve_signing_key, run

PROBES = (
    'DecoderProbe', 'InteractionProbe', 'HomeProbe', 'LoadingProbe', 'StartupProbe',
    'ExperienceProbe', 'MotionProbe', 'SearchCaseProbe', 'PerformanceProbe', 'DetailProbe',
    'ConfigLiveProbe', 'UpdateProbe', 'LayoutProbe', 'ResponsiveProbe', 'MobilePlayerProbe',
    'SourceHostProbe',
)
OUT_NAMES = {
    'SourceHostProbe': 'source-host-probe',
    'MobilePlayerProbe': 'mobile-player-probe',
    'ResponsiveProbe': 'responsive-probe',
    'LayoutProbe': 'layout-probe',
    'UpdateProbe': 'update-probe',
    'ConfigLiveProbe': 'config-live-probe',
    'DetailProbe': 'detail-probe',
    'PerformanceProbe': 'performance-probe',
    'SearchCaseProbe': 'search-case-probe',
    'MotionProbe': 'motion-probe',
    'ExperienceProbe': 'experience-probe',
    'StartupProbe': 'startup-probe',
    'LoadingProbe': 'probe',
    'DecoderProbe': 'decoder-probe',
    'HomeProbe': 'home-probe',
    'InteractionProbe': 'interaction-probe',
}

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('probe_name', nargs='?', default='DecoderProbe', choices=PROBES)
parser.add_argument(
    '--module',
    choices=('android-tv', 'android-mobile'),
    default=None,
    help='Target Android module directory (defaults to android-mobile for MobilePlayerProbe, android-tv otherwise).',
)
args = parser.parse_args()
probe_name = args.probe_name
module_name = args.module or ('android-mobile' if probe_name == 'MobilePlayerProbe' else 'android-tv')
MODULE = ROOT / module_name
BUILD = MODULE / 'build'
app_classes = BUILD / 'classes.jar'
if not app_classes.exists():
    builder = 'scripts/build_android_mobile.py' if module_name == 'android-mobile' else 'scripts/build_android_tv.py'
    raise RuntimeError(f'Missing {app_classes}; run {builder} first')

out = BUILD / OUT_NAMES[probe_name]
out.mkdir(parents=True, exist_ok=True)
for d in ('classes', 'dex'):
    folder = out / d
    folder.mkdir(exist_ok=True)
    for old in folder.rglob('*.class' if d == 'classes' else '*.dex'):
        old.unlink()

manifest = out / 'AndroidManifest.xml'
manifest.write_text(
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test">'
    '<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>'
    '<application android:label="Marco Movie local test"/>'
    f'<instrumentation android:name="com.pilipala.marcomovie.{probe_name}" android:targetPackage="com.pilipala.marcomovie"/>'
    '</manifest>',
    encoding='utf-8',
)
assets = []
if probe_name == 'MobilePlayerProbe':
    # Deterministic local media: this verifies seeking/layout, not video codecs.
    folder = out / 'assets'
    folder.mkdir(exist_ok=True)
    with wave.open(str(folder / 'timeline.wav'), 'wb') as audio:
        audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
        audio.writeframes(b'\x00\x00' * 8000 * 60)
    assets = ['-A', folder]

run(exe(SDK, 'aapt2'), 'link', '-o', out / 'resources.apk', '--manifest', manifest, '-I', ANDROID, *assets)
extra_cp = (os.pathsep + str(ROOT / 'tools/java-dependencies/core-3.5.3.jar')) if probe_name == 'ConfigLiveProbe' else ''
probe_source = MODULE / 'tests/device' / (probe_name + '.java')
run(
    exe(JDK / 'bin', 'javac'), '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
    '-classpath', str(ANDROID) + os.pathsep + str(app_classes) + extra_cp,
    '-d', out / 'classes', probe_source,
)
with zipfile.ZipFile(out / 'classes.jar', 'w') as z:
    for p in (out / 'classes').rglob('*.class'):
        z.write(p, p.relative_to(out / 'classes').as_posix())
run(
    exe(JDK / 'bin', 'java'), '-cp', SDK / 'lib/d8.jar', 'com.android.tools.r8.D8',
    '--min-api', '23', '--lib', ANDROID, '--classpath', app_classes,
    '--output', out / 'dex', out / 'classes.jar',
)
with zipfile.ZipFile(out / 'resources.apk') as src, zipfile.ZipFile(out / 'unsigned.apk', 'w', zipfile.ZIP_DEFLATED) as dst:
    for n in src.namelist():
        dst.writestr(n, src.read(n))
    for dex in sorted((out / 'dex').glob('*.dex')):
        dst.write(dex, dex.name)
run(exe(SDK, 'zipalign'), '-f', '4', out / 'unsigned.apk', out / 'aligned.apk')
signing_key = resolve_signing_key(MODULE)
run(
    exe(JDK / 'bin', 'java'), '-jar', SDK / 'lib/apksigner.jar', 'sign',
    '--ks', signing_key, '--ks-key-alias', 'marcomovie', '--ks-pass', 'env:MARCOMOVIE_KEY_PASSWORD',
    '--out', out / 'probe.apk', out / 'aligned.apk',
)
print(out / 'probe.apk')
if probe_name == 'MobilePlayerProbe':
    # x86_64 UI verification deliberately omits ARM-only native libraries.
    # Never replace dist packages with this test-only derivative.
    source = BUILD / 'unsigned-mobile.apk'
    if not source.exists():
        raise RuntimeError(f'Missing {source}; run scripts/build_android_mobile.py first')
    with zipfile.ZipFile(source) as src, zipfile.ZipFile(out / 'layout-only-unsigned.apk', 'w', zipfile.ZIP_DEFLATED) as dst:
        for entry in src.infolist():
            if not entry.filename.startswith('lib/'):
                dst.writestr(entry, src.read(entry.filename))
    run(exe(SDK, 'zipalign'), '-f', '4', out / 'layout-only-unsigned.apk', out / 'layout-only-aligned.apk')
    run(
        exe(JDK / 'bin', 'java'), '-jar', SDK / 'lib/apksigner.jar', 'sign',
        '--ks', signing_key, '--ks-key-alias', 'marcomovie', '--ks-pass', 'env:MARCOMOVIE_KEY_PASSWORD',
        '--out', out / 'layout-only.apk', out / 'layout-only-aligned.apk',
    )
    (out / 'scope.json').write_text(
        json.dumps(
            {
                'scope': 'UI and system-player seeking only; ARM native libraries omitted. Not a distributable APK or CatPaw/decoder acceptance.',
                'module': module_name,
                'production_unsigned_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'production_classes_sha256': hashlib.sha256(app_classes.read_bytes()).hexdigest(),
                'test_apk_sha256': hashlib.sha256((out / 'layout-only.apk').read_bytes()).hexdigest(),
                'probe_apk_sha256': hashlib.sha256((out / 'probe.apk').read_bytes()).hexdigest(),
            },
            indent=2,
        ) + '\n',
        encoding='utf-8',
    )
