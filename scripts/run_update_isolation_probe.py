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
    return subprocess.run([ADB, *args], capture_output=True, text=True, encoding='utf-8', errors='replace', check=check, timeout=180).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        '--edition',
        choices=('mobile', 'tv', 'both'),
        default=None,
        help='Edition(s) to verify (defaults to mobile if android-mobile/build/update-isolation exists, else both in android-tv).',
    )
    args = parser.parse_args()
    if args.edition == 'mobile':
        out = ROOT / 'android-mobile/build/update-isolation'
        editions = ('mobile',)
    elif args.edition == 'tv':
        out = ROOT / 'android-tv/build/update-isolation'
        editions = ('tv',)
    elif args.edition == 'both':
        out = ROOT / 'android-tv/build/update-isolation'
        editions = ('mobile', 'tv')
    else:
        mobile_out = ROOT / 'android-mobile/build/update-isolation'
        tv_out = ROOT / 'android-tv/build/update-isolation'
        if mobile_out.exists() and not tv_out.exists():
            out = mobile_out
            editions = ('mobile',)
        else:
            out = tv_out
            editions = ('mobile', 'tv')

    if adb('shell', 'getprop', 'ro.kernel.qemu').strip() != '1':
        raise RuntimeError('Only disposable emulators may run this installation test')
    (out / 'device.txt').write_text(adb('shell', 'getprop'), encoding='utf-8')
    reports = {}
    for edition in editions:
        adb('uninstall', 'com.pilipala.marcomovie.test', check=False)
        adb('uninstall', 'com.pilipala.marcomovie', check=False)
        adb('install', '--no-incremental', str(out / (edition + '.apk')))
        probe_apk = out / f'probe-{edition}.apk'
        if not probe_apk.exists():
            probe_apk = out / 'probe.apk'
        adb('install', '--no-incremental', str(probe_apk))
        raw = adb('shell', 'am', 'instrument', '-w', '-e', 'edition', edition,
                  'com.pilipala.marcomovie.test/com.pilipala.marcomovie.UpdateIsolationProbe')
        (out / (edition + '.log')).write_text(raw, encoding='utf-8')
        match = re.search(r'INSTRUMENTATION_STATUS: result=(\{[^\r\n]+\})', raw)
        if not match:
            raise RuntimeError('Missing instrumentation report: ' + edition)
        report = json.loads(match[1])
        reports[edition] = report
        (out / 'results.json').write_text(json.dumps(reports, indent=2) + '\n', encoding='utf-8')
        if report.get('passed') is not True or report.get('checks') != 18 or report.get('edition') != edition:
            raise RuntimeError('Update isolation check failed: ' + json.dumps(report))
    print(json.dumps(reports, indent=2))


if __name__ == '__main__':
    main()
