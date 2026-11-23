"""Mobile-directory entrypoint to build and optionally run Android Mobile device probes.

Builds against android-mobile/build/ artifacts produced by scripts/build_android_mobile.py:
  - MobilePlayerProbe -> android-mobile/build/mobile-player-probe/
  - SourceHostProbe (phone) -> android-mobile/build/phone-source-probe/
  - UpdateIsolationProbe (mobile) -> android-mobile/build/update-isolation/
"""
from pathlib import Path
import argparse
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]


def run_step(args):
    subprocess.run([sys.executable, '-X', 'utf8', *args], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        'target',
        choices=('player', 'source', 'update-isolation', 'all'),
        default='all',
        nargs='?',
    )
    parser.add_argument(
        '--run',
        action='store_true',
        help='Execute the built probe(s) on a connected disposable Android emulator via adb.',
    )
    parser.add_argument('--navigation', choices=('gestural', 'threebutton'), default='gestural')
    args = parser.parse_args()

    targets = ('player', 'source', 'update-isolation') if args.target == 'all' else (args.target,)
    if 'player' in targets:
        run_step(['scripts/build_device_probe.py', 'MobilePlayerProbe', '--module', 'android-mobile'])
        if args.run:
            run_step(['scripts/run_mobile_player_probe.py', '--navigation', args.navigation])
    if 'source' in targets:
        run_step(['scripts/build_api23_probes.py', '--phone'])
        if args.run:
            run_step(['scripts/run_phone_source_probe.py'])
    if 'update-isolation' in targets:
        run_step(['scripts/build_update_isolation_probe.py', '--edition', 'mobile'])
        if args.run:
            run_step(['scripts/run_update_isolation_probe.py', '--edition', 'mobile'])


if __name__ == '__main__':
    main()
