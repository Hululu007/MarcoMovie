"""Build production-code update fixtures; candidate APKs are parsed but never installed."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile

from android_build_common import ANDROID, JDK, ROOT, SDK, exe, resolve_signing_key, run
from sync_movie_mirror import apk_identity


def next_version(ver):
    parts = ver.split('.')
    return '.'.join(parts[:2] + [str(int(parts[2]) + 1)])


def edition_meta(edition, root: Path = ROOT):
    module = root / ('android-mobile' if edition == 'mobile' else 'android-tv')
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


def default_editions(root: Path = ROOT):
    """Select only editions whose production build artifacts actually exist."""
    has_tv = (root / 'android-tv/build/unsigned.apk').exists()
    has_mobile = (root / 'android-mobile/build/unsigned-mobile.apk').exists()
    if has_tv and has_mobile:
        return ('tv', 'mobile')
    if has_mobile:
        return ('mobile',)
    if has_tv:
        return ('tv',)
    raise RuntimeError(
        'No built Android TV or Mobile unsigned APK found; run scripts/build_android_tv.py or scripts/build_android_mobile.py first'
    )


def sign(out_dir, module_dir, source, destination, wrong=False):
    key = out_dir / 'wrong.p12' if wrong else resolve_signing_key(module_dir)
    if wrong and not key.exists():
        run(
            exe(JDK / 'bin', 'keytool'),
            '-genkeypair',
            '-alias',
            'marcomovie',
            '-keystore',
            key,
            '-storepass',
            'fixture',
            '-keypass',
            'fixture',
            '-dname',
            'CN=Isolated fixture',
            '-keyalg',
            'RSA',
            '-validity',
            '30',
        )
    run(
        exe(JDK / 'bin', 'java'),
        '-jar',
        SDK / 'lib/apksigner.jar',
        'sign',
        '--ks',
        key,
        '--ks-key-alias',
        'marcomovie',
        '--ks-pass',
        'pass:fixture' if wrong else 'env:MARCOMOVIE_KEY_PASSWORD',
        '--out',
        destination,
        source,
    )


def apk_cert_sha256(apk_path: Path) -> str:
    out = run(
        exe(JDK / 'bin', 'java'),
        '-jar',
        SDK / 'lib/apksigner.jar',
        'verify',
        '--print-certs',
        apk_path,
        capture=True,
    )
    match = re.search(r'SHA-256 digest:\s*([0-9a-fA-F]{64})', out or '')
    if not match:
        raise RuntimeError(f'Unable to read signer SHA-256 from {apk_path}')
    return match.group(1).lower()


def build_for_single_edition(edition: str, root: Path = ROOT) -> Path:
    """Build isolated host, probe, and candidate fixtures inside this edition's own build dir.

    Every matching candidate fixture is signed with this edition's own signing key (matching its
    host APK even when TV and Mobile use independent ephemeral CI keys), while wrong-signer
    fixtures use a separate generated keystore.
    """
    all_meta = {ed: edition_meta(ed, root=root) for ed in ('tv', 'mobile')}
    meta = all_meta[edition]
    if not meta['unsigned_apk'].exists() or not meta['classes_jar'].exists():
        builder = 'scripts/build_android_mobile.py' if edition == 'mobile' else 'scripts/build_android_tv.py'
        raise RuntimeError(f'Missing {edition} build artifacts; run {builder} first')

    out = meta['module'] / 'build/update-isolation'
    (out / 'assets').mkdir(parents=True, exist_ok=True)
    for sub in ('classes', 'dex', 'classes-' + edition, 'dex-' + edition):
        folder = out / sub
        folder.mkdir(exist_ok=True)
        for old in folder.rglob('*'):
            if old.is_file():
                old.unlink()

    for target in ('tv', 'mobile'):
        target_meta = all_meta[target]
        version = next_version(target_meta['versionName'])
        code = target_meta['versionCode'] + 1
        opposite_edition = 'mobile' if target == 'tv' else 'tv'
        variants = [
            (target, target, False),
            ('wrong-signer-' + target, target, True),
            ('opposite-' + target, opposite_edition, False),
            ('missing-' + target, None, False),
            ('unknown-' + target, 'unknown', False),
        ]
        for name, cand_edition, wrong in variants:
            metadata = (
                ''
                if cand_edition is None
                else f'<meta-data android:name="com.pilipala.marcomovie.EDITION" android:value="{cand_edition}"/>'
            )
            manifest = out / (name + '.xml')
            manifest.write_text(
                f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie" android:versionCode="{code}" android:versionName="{version}">'
                f'<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>'
                f'<application android:label="Never install">{metadata}</application></manifest>',
                encoding='utf-8',
            )
            unsigned = out / (name + '-unsigned.apk')
            run(exe(SDK, 'aapt2'), 'link', '-o', unsigned, '--manifest', manifest, '-I', ANDROID)
            sign(out, meta['module'], unsigned, out / 'assets' / (name + '.apk'), wrong=wrong)

    # Verify the mirror's binary manifest reader against real aapt2 output too.
    for target in ('tv', 'mobile'):
        target_meta = all_meta[target]
        expected_version = next_version(target_meta['versionName'])
        expected_code = target_meta['versionCode'] + 1
        identity = apk_identity((out / 'assets' / (target + '.apk')).read_bytes())
        assert (
            identity['edition'] == target
            and identity['versionCode'] == expected_code
            and identity['versionName'] == expected_version
        )

    manifest = out / 'AndroidManifest.xml'
    manifest.write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.pilipala.marcomovie.test">'
        '<uses-sdk android:minSdkVersion="23" android:targetSdkVersion="28"/>'
        '<application/><instrumentation android:name="com.pilipala.marcomovie.UpdateIsolationProbe" android:targetPackage="com.pilipala.marcomovie"/></manifest>',
        encoding='utf-8',
    )
    run(
        exe(SDK, 'aapt2'),
        'link',
        '-o',
        out / 'probe-resources.apk',
        '--manifest',
        manifest,
        '-I',
        ANDROID,
        '-A',
        out / 'assets',
    )

    ed_classes = out / ('classes-' + edition)
    ed_dex = out / ('dex-' + edition)
    run(
        exe(JDK / 'bin', 'javac'),
        '-encoding',
        'UTF-8',
        '-source',
        '8',
        '-target',
        '8',
        '-Xlint:-options',
        '-classpath',
        str(ANDROID) + os.pathsep + str(meta['classes_jar']),
        '-d',
        ed_classes,
        meta['probe_java'],
    )
    probe_jar = out / f'probe-{edition}-classes.jar'
    with zipfile.ZipFile(probe_jar, 'w') as jar:
        for file in ed_classes.rglob('*.class'):
            jar.write(file, file.relative_to(ed_classes).as_posix())
    run(
        exe(JDK / 'bin', 'java'),
        '-cp',
        SDK / 'lib/d8.jar',
        'com.android.tools.r8.D8',
        '--min-api',
        '23',
        '--lib',
        ANDROID,
        '--classpath',
        meta['classes_jar'],
        '--output',
        ed_dex,
        probe_jar,
    )
    probe_unsigned = out / f'probe-{edition}-unsigned.apk'
    with zipfile.ZipFile(out / 'probe-resources.apk') as src, zipfile.ZipFile(
        probe_unsigned, 'w', zipfile.ZIP_DEFLATED
    ) as dst:
        for entry in src.infolist():
            dst.writestr(entry, src.read(entry.filename))
        for dex in sorted(ed_dex.glob('*.dex')):
            dst.write(dex, dex.name)
    sign(out, meta['module'], probe_unsigned, out / f'probe-{edition}.apk')
    sign(out, meta['module'], probe_unsigned, out / 'probe.apk')

    with zipfile.ZipFile(meta['unsigned_apk']) as src, zipfile.ZipFile(
        out / (edition + '-unsigned.apk'), 'w', zipfile.ZIP_DEFLATED
    ) as dst:
        for entry in src.infolist():
            if not entry.filename.startswith('lib/'):
                dst.writestr(entry, src.read(entry.filename))
    host_apk = out / (edition + '.apk')
    sign(out, meta['module'], out / (edition + '-unsigned.apk'), host_apk)

    host_signer = apk_cert_sha256(host_apk)
    positive_signer = apk_cert_sha256(out / 'assets' / (edition + '.apk'))
    wrong_signer = apk_cert_sha256(out / 'assets' / ('wrong-signer-' + edition + '.apk'))
    if host_signer != positive_signer:
        raise RuntimeError(f'{edition} host signer {host_signer} != positive fixture signer {positive_signer}')
    if host_signer == wrong_signer:
        raise RuntimeError(f'{edition} wrong-signer fixture accidentally shares host signer {host_signer}')

    (out / 'scope.json').write_text(
        json.dumps(
            {
                'scope': 'Production updater and Android package parser only. Native media libraries omitted; no source/decoder/device acceptance. Candidate updates never installed.',
                'edition': edition,
                'editions': [edition],
                'production_classes_sha256': hashlib.sha256(meta['classes_jar'].read_bytes()).hexdigest(),
                'fixture_sha256': {edition: hashlib.sha256(host_apk.read_bytes()).hexdigest()},
                'host_signer_sha256': host_signer,
                'positive_fixture_signer_sha256': positive_signer,
                'wrong_fixture_signer_sha256': wrong_signer,
                'manifest_versions': {
                    ed: {'versionName': all_meta[ed]['versionName'], 'versionCode': all_meta[ed]['versionCode']}
                    for ed in ('tv', 'mobile')
                },
            },
            indent=2,
        )
        + '\n',
        encoding='utf-8',
    )
    print(out)
    return out


def build_for_editions(editions, root: Path = ROOT):
    outputs = {}
    for edition in editions:
        outputs[edition] = build_for_single_edition(edition, root=root)
    return outputs


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
        editions = default_editions(ROOT)
    build_for_editions(editions, root=ROOT)


if __name__ == '__main__':
    main()
