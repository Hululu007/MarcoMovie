"""Batch 1 regression checks (#72/#73 MPV crash & native trace, #71 Home posters, #14/#2 source rejection & parse stages).

Also verifies the 0.6.0 counterexample via git show to document what failed in 0.6.0 vs 0.7.0+.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()


def verify_060_counterexamples():
    old_movie = subprocess.check_output(
        ['git', 'show', '36333b602697ec02afeb3587f273acd7f150b27c:android/src/main/java/com/pilipala/marcomovie/MoviePlayer.java'],
        cwd=ROOT,
    ).decode('utf-8')
    old_mpv = subprocess.check_output(
        ['git', 'show', '36333b602697ec02afeb3587f273acd7f150b27c:android/src/main/java/com/pilipala/marcomovie/MpvPlayer.java'],
        cwd=ROOT,
    ).decode('utf-8')
    idx = old_movie.index('public java.util.List<String> mediaBadges()')
    old_media_badges = old_movie[idx : idx + 500]
    assert 'if (released) return out;' in old_media_badges and 'exo == null' not in old_media_badges, (
        'Expected 0.6.0 MoviePlayer.mediaBadges() to lack exo == null guard'
    )
    assert 'mediaBadges()' not in old_mpv, (
        'Expected 0.6.0 MpvPlayer to lack mediaBadges() override'
    )
    assert 'MPVLib.setOptionString("vo", configuredVo);' in old_mpv, (
        'Expected 0.6.0 MpvPlayer to enable vo before attachSurface()'
    )
    print('PASS #72/#73 0.6.0 baseline counterexample confirmed (missing MpvPlayer.mediaBadges & MoviePlayer exo==null guard)')


def main():
    verify_060_counterexamples()
    with tempfile.TemporaryDirectory(prefix='batch1-mobile-checks-') as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / 'classes'
        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[ROOT / 'android-mobile/tests/Batch1MobileChecks.java'],
        )
        run_cp = os.pathsep.join(str(p) for p in runtime_cp)
        subprocess.run(
            [
                str(JDK / ('java' + SUFFIX)),
                '-Dfile.encoding=UTF-8',
                '-cp',
                run_cp,
                'com.pilipala.marcomovie.Batch1MobileChecks',
                str(ROOT),
            ],
            cwd=ROOT,
            check=True,
        )


if __name__ == '__main__':
    main()
