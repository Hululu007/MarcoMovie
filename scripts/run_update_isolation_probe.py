"""Run edition/update checks only on a disposable Android emulator."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ADB = os.environ.get('ADB', 'adb')


def adb(*args, check=True):
    return subprocess.run(
        [ADB, *args],
        capture_output=True,
        text=True,
        encoding='utf-8',
        errors='replace',
        check=check,
        timeout=180,
    ).stdout


def edition_output_dir(edition: str, root: Path = ROOT) -> Path:
    module = 'android-mobile' if edition == 'mobile' else 'android-tv'
    return root / module / 'build/update-isolation'


def resolve_editions(explicit: str | None, root: Path = ROOT):
    if explicit == 'mobile':
        return ('mobile',)
    if explicit == 'tv':
        return ('tv',)
    if explicit == 'both':
        return ('tv', 'mobile')
    has_tv = (edition_output_dir('tv', root) / 'tv.apk').exists()
    has_mobile = (edition_output_dir('mobile', root) / 'mobile.apk').exists()
    if has_tv and has_mobile:
        return ('tv', 'mobile')
    if has_mobile:
        return ('mobile',)
    if has_tv:
        return ('tv',)
    raise RuntimeError(
        'No built update-isolation probe directory found; run scripts/build_update_isolation_probe.py first'
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--edition',
        choices=('mobile', 'tv', 'both'),
        default=None,
        help='Edition(s) to verify (defaults to built update-isolation directories).',
    )
    args = parser.parse_args()
    editions = resolve_editions(args.edition, ROOT)

    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('Only disposable emulators may run this installation test')

    device_props = adb('shell', 'getprop')
    reports = {}
    for edition in editions:
        out = edition_output_dir(edition, ROOT)
        host_apk = out / (edition + '.apk')
        probe_apk = out / f'probe-{edition}.apk'
        if not probe_apk.exists():
            probe_apk = out / 'probe.apk'
        if not host_apk.exists() or not probe_apk.exists():
            raise RuntimeError(
                f'Missing {edition} update-isolation probe artifacts in {out}; run scripts/build_update_isolation_probe.py --edition {edition}'
            )
        (out / 'device.txt').write_text(device_props, encoding='utf-8')
        adb('uninstall', 'com.pilipala.marcomovie.test', check=False)
        adb('uninstall', 'com.pilipala.marcomovie', check=False)
        adb('install', '--no-incremental', str(host_apk))
        adb('install', '--no-incremental', str(probe_apk))
        raw = adb(
            'shell',
            'am',
            'instrument',
            '-w',
            '-e',
            'edition',
            edition,
            'com.pilipala.marcomovie.test/com.pilipala.marcomovie.UpdateIsolationProbe',
        )
        (out / (edition + '.log')).write_text(raw, encoding='utf-8')
        match = re.search(r'INSTRUMENTATION_STATUS: result=(\{[^\r\n]+\})', raw)
        if not match:
            raise RuntimeError('Missing instrumentation report: ' + edition)
        report = json.loads(match[1])
        reports[edition] = report
        # Preserve each edition's own results.json in its own output directory without overwriting.
        (out / 'results.json').write_text(
            json.dumps({edition: report}, indent=2) + '\n', encoding='utf-8'
        )
        if report.get('passed') is not True or report.get('checks') != 18 or report.get('edition') != edition:
            raise RuntimeError('Update isolation check failed: ' + json.dumps(report))
    print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
