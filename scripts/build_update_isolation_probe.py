"""Build production-code update fixtures; candidate APKs are parsed but never installed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import xml.etree.ElementTree as ET
import zipfile

from android_build_common import ANDROID, JDK, ROOT, SDK, exe, resolve_signing_key, run
from sync_movie_mirror import apk_identity


def next_version(ver):
    parts = ver.split('.')
    return '.'.join(parts[:2] + [str(int(parts[2]) + 1)])


def edition_meta(edition):
    module = ROOT / ('android-mobile' if edition == 'mobile' else 'android-tv')
    attrs = ET.parse(module / 'src/main/AndroidManifest.xml').getroot().attrib
    ns = '{http://schemas.android.com/apk/res/android}'
    default_version = attrs[ns + 'versionName']
    default_code = int(attrs[ns + 'versionCode'])
    versions_file = module / 'edition-versions.json'
    versions = json.loads(versions_file.read_text(encoding='utf-8')) if versions_file.exists() else {}
    meta = versions.get('android-' + edition, {})
    return {
        'module': module,
        'versionName': meta.get('versionName', default_version),
        'versionCode': int(meta.get('versionCode', default_code)),
        'unsigned_apk': module / 'build' / ('unsigned-mobile.apk' if edition == 'mobile' else 'unsigned.apk'),
        'classes_jar': module / 'build/classes.jar',
        'probe_java': module / 'tests/device/UpdateIsolationProbe.java',
    }


def sign(out_dir, module_dir, source, destination, wrong=False):
    key = out_dir / 'wrong.p12' if wrong else resolve_signing_key(module_dir)
    if wrong and not key.exists():
        run(exe(JDK / 'bin', 'keytool'), '-genkeypair', '-alias', 'marcomovie', '-keystore', key,
            '-storepass', 'fixture', '-keypass', 'fixture', '-dname', 'CN=Isolated fixture', '-keyalg', 'RSA', '-validity', '30')
    run(exe(JDK / 'bin', 'java'), '-jar', SDK / 'lib/apksigner.jar', 'sign', '--ks', key,
        '--ks-key-alias', 'marcomovie', '--ks-pass', 'pass:fixture' if wrong else 'env:MARCOMOVIE_KEY_PASSWORD',
        '--out', destination, source)


def build_for_editions(editions):
    primary = editions[0]
    primary_meta = edition_meta(primary)
    out = primary_meta['module'] / 'build/update-isolation'
    (out / 'assets').mkdir(parents=True, exist_ok=True)
    for sub in ('classes', 'dex'):
        folder = out / sub
        folder.mkdir(exist_ok=True)
        for old in folder.rglob('*.class' if sub == 'classes' else '*.dex'):
            old.unlink()

    all_meta = {ed: edition_meta(ed) for ed in ('tv', 'mobile')}
    for target in ('tv', 'mobile'):
        meta = all_meta[target]
        version = next_version(meta['versionName'])
        code = meta['versionCode'] + 1
        opposite_edition = 'mobile' if target == 'tv' else 'tv'
        variants = [
            (target, target, False),
            ('wrong-signer-' + target, target, True),
            ('opposite-' + target, opposite_edition, False),
            ('missing-' + target, None, False),
            ('unknown-' + target, 'unknown', False),
        ]
        for name, edition, wrong in variants:
            metadata = '' if edition is None else f'<meta-data android:name="com.pilipala.marcomovie.EDITION" android:value="{edition}"/>'
            manifest = out / (name + '.xml')
            manifest.write_text(
                f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie" android:versionCode="{code}" android:versionName="{version}">'
                f'<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>'
                f'<application android:label="Never install">{metadata}</application></manifest>',
                encoding='utf-8',
            )
            unsigned = out / (name + '-unsigned.apk')
            run(exe(SDK, 'aapt2'), 'link', '-o', unsigned, '--manifest', manifest, '-I', ANDROID)
            sign(out, primary_meta['module'], unsigned, out / 'assets' / (name + '.apk'), wrong=wrong)

    # Verify the mirror's binary manifest reader against real aapt2 output too.
    for edition in ('tv', 'mobile'):
        meta = all_meta[edition]
        expected_version = next_version(meta['versionName'])
        expected_code = meta['versionCode'] + 1
        identity = apk_identity((out / 'assets' / (edition + '.apk')).read_bytes())
        assert identity['edition'] == edition and identity['versionCode'] == expected_code and identity['versionName'] == expected_version

    manifest = out / 'AndroidManifest.xml'
    manifest.write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test">'
        '<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>'
        '<application/><instrumentation android:name="com.pilipala.marcomovie.UpdateIsolationProbe" android:targetPackage="com.pilipala.marcomovie"/></manifest>',
        encoding='utf-8',
    )
    run(exe(SDK, 'aapt2'), 'link', '-o', out / 'probe-resources.apk', '--manifest', manifest, '-I', ANDROID, '-A', out / 'assets')

    hashes = {}
    classes_hashes = {}
    for edition in editions:
        meta = all_meta[edition]
        if not meta['unsigned_apk'].exists() or not meta['classes_jar'].exists():
            builder = 'scripts/build_android_mobile.py' if edition == 'mobile' else 'scripts/build_android_tv.py'
            raise RuntimeError(f'Missing {edition} build artifacts; run {builder} first')
        ed_classes = out / ('classes-' + edition)
        ed_dex = out / ('dex-' + edition)
        for folder in (ed_classes, ed_dex):
            folder.mkdir(exist_ok=True)
            for old in folder.rglob('*'):
                if old.is_file():
                    old.unlink()
        run(
            exe(JDK / 'bin', 'javac'), '-encoding', 'UTF-8', '-source', '8', '-target', '8', '-Xlint:-options',
            '-classpath', str(ANDROID) + os.pathsep + str(meta['classes_jar']),
            '-d', ed_classes, meta['probe_java'],
        )
        probe_jar = out / (f'probe-{edition}-classes.jar')
        with zipfile.ZipFile(probe_jar, 'w') as jar:
            for file in ed_classes.rglob('*.class'):
                jar.write(file, file.relative_to(ed_classes).as_posix())
        run(
            exe(JDK / 'bin', 'java'), '-cp', SDK / 'lib/d8.jar', 'com.android.tools.r8.D8',
            '--min-api', '23', '--lib', ANDROID, '--classpath', meta['classes_jar'],
            '--output', ed_dex, probe_jar,
        )
        probe_unsigned = out / f'probe-{edition}-unsigned.apk'
        with zipfile.ZipFile(out / 'probe-resources.apk') as src, zipfile.ZipFile(probe_unsigned, 'w', zipfile.ZIP_DEFLATED) as dst:
            for entry in src.infolist():
                dst.writestr(entry, src.read(entry.filename))
            for dex in sorted(ed_dex.glob('*.dex')):
                dst.write(dex, dex.name)
        sign(out, meta['module'], probe_unsigned, out / f'probe-{edition}.apk')
        if edition == primary:
            sign(out, meta['module'], probe_unsigned, out / 'probe.apk')

        with zipfile.ZipFile(meta['unsigned_apk']) as src, zipfile.ZipFile(out / (edition + '-unsigned.apk'), 'w', zipfile.ZIP_DEFLATED) as dst:
            for entry in src.infolist():
                if not entry.filename.startswith('lib/'):
                    dst.writestr(entry, src.read(entry.filename))
        sign(out, meta['module'], out / (edition + '-unsigned.apk'), out / (edition + '.apk'))
        hashes[edition] = hashlib.sha256((out / (edition + '.apk')).read_bytes()).hexdigest()
        classes_hashes[edition] = hashlib.sha256(meta['classes_jar'].read_bytes()).hexdigest()

    (out / 'scope.json').write_text(
        json.dumps(
            {
                'scope': 'Production updater and Android package parser only. Native media libraries omitted; no source/decoder/device acceptance. Candidate updates never installed.',
                'editions': list(editions),
                'production_classes_sha256': classes_hashes if len(editions) > 1 else classes_hashes[primary],
                'fixture_sha256': hashes,
                'manifest_versions': {
                    ed: {'versionName': all_meta[ed]['versionName'], 'versionCode': all_meta[ed]['versionCode']}
                    for ed in ('tv', 'mobile')
                },
            },
            indent=2,
        ) + '\n',
        encoding='utf-8',
    )
    print(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--edition',
        choices=('mobile', 'tv', 'both'),
        default=None,
        help='Edition(s) to build host fixtures for (defaults to built editions).',
    )
    args = parser.parse_args()
    if args.edition == 'mobile':
        editions = ('mobile',)
    elif args.edition == 'tv':
        editions = ('tv',)
    elif args.edition == 'both':
        editions = ('tv', 'mobile')
    else:
        has_tv = (ROOT / 'android-tv/build/unsigned.apk').exists()
        has_mobile = (ROOT / 'android-mobile/build/unsigned-mobile.apk').exists()
        if has_tv and has_mobile:
            editions = ('tv', 'mobile')
        elif has_mobile:
            editions = ('mobile',)
        else:
            editions = ('tv', 'mobile')
    build_for_editions(editions)


if __name__ == '__main__':
    main()
