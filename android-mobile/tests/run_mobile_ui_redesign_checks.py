"""Dedicated QA checks for the Android Mobile global UI redesign."""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()


def main():
    with tempfile.TemporaryDirectory(prefix='mobile-ui-redesign-checks-') as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / 'classes'
        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[ROOT / 'android-mobile/tests/MobileUiRedesignChecks.java'],
        )
        run_cp = os.pathsep.join(str(p) for p in runtime_cp)
        subprocess.run(
            [
                str(JDK / ('java' + SUFFIX)),
                '-Dfile.encoding=UTF-8',
                '-cp',
                run_cp,
                'com.pilipala.marcomovie.MobileUiRedesignChecks',
                str(ROOT),
            ],
            cwd=ROOT,
            check=True,
        )


if __name__ == '__main__':
    main()
