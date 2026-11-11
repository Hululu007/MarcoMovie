"""Build official Media3 software decoders on Linux, for Android API 23 ARMv7 and ARM64.

No application credentials or content are inputs. Every source is commit-pinned.
The resulting source archive accompanies distributed native binaries.
"""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, tarfile, zipfile

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / 'native-work'
OUT = ROOT / 'native-output'
SOURCES = json.loads(Path(__file__).with_name('sources.json').read_text())
NDK = Path(os.environ.get('ANDROID_NDK_HOME') or os.environ['ANDROID_HOME'] + '/ndk/26.1.10909125')
BIN = NDK / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
JOBS = str(min(os.cpu_count() or 2, 4))
PAGE_SIZE_FLAG = '-Wl,-z,max-page-size=16384'

TARGETS = [
    {
        'abi': 'armeabi-v7a',
        'zip_suffix': 'armv7',
        'cc': BIN / 'armv7a-linux-androideabi23-clang',
        'cxx': BIN / 'armv7a-linux-androideabi23-clang++',
        'ffmpeg_arch': 'arm',
        'ffmpeg_extra': ['--cpu=armv7-a', '--extra-cflags=-march=armv7-a -mfloat-abi=softfp'],
        'vpx_target': 'armv7-linux-gcc',
    },
    {
        'abi': 'arm64-v8a',
        'zip_suffix': 'arm64',
        'cc': BIN / 'aarch64-linux-android23-clang',
        'cxx': BIN / 'aarch64-linux-android23-clang++',
        'ffmpeg_arch': 'aarch64',
        'ffmpeg_extra': ['--extra-cflags=-O2'],
        'vpx_target': 'arm64-linux-gcc',
    },
]

def run(*args, cwd=None, env=None):
    subprocess.run([str(x) for x in args], cwd=cwd or ROOT, env=env, check=True)

def checkout(name):
    target = WORK / name
    if not target.exists():
        target.mkdir(parents=True)
        run('git', 'init', target)
        run('git', 'fetch', '--depth=1', SOURCES[name]['url'], SOURCES[name]['commit'], cwd=target)
        run('git', 'checkout', '--detach', 'FETCH_HEAD', cwd=target)
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=target, text=True).strip()
    if actual != SOURCES[name]['commit']:
        raise RuntimeError('Unexpected source checkout: ' + name)
    return target

def cmake(jni, build, abi):
    run('cmake', '-S', jni, '-B', build, '-G', 'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE=' + str(NDK / 'build/cmake/android.toolchain.cmake'),
        '-DANDROID_ABI=' + abi, '-DANDROID_PLATFORM=android-23',
        '-DANDROID_STL=c++_static', '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_SHARED_LINKER_FLAGS=' + PAGE_SIZE_FLAG,
        '-DBUILD_TESTING=OFF', '-DLIBGAV1_ENABLE_TESTS=OFF', '-DLIBGAV1_ENABLE_EXAMPLES=OFF')
    run('cmake', '--build', build, '--parallel', JOBS)

def build_abi(target, src, decoders):
    abi = target['abi']
    cc = target['cc']
    cxx = target['cxx']
    media = src['media'] / 'libraries'
    ff = src['ffmpeg']
    if (ff / 'config.h').exists() or (ff / 'ffbuild/config.mak').exists():
        subprocess.run(['make', 'distclean'], cwd=ff, check=False)
    run(ff / 'configure', '--target-os=android', '--arch=' + target['ffmpeg_arch'],
        *target['ffmpeg_extra'],
        '--enable-cross-compile', '--cc=' + str(cc), '--cxx=' + str(cxx),
        '--ar=' + str(BIN / 'llvm-ar'), '--nm=' + str(BIN / 'llvm-nm'),
        '--ranlib=' + str(BIN / 'llvm-ranlib'), '--strip=' + str(BIN / 'llvm-strip'),
        '--enable-static', '--disable-shared', '--enable-pic', '--disable-doc',
        '--disable-programs', '--disable-everything', '--disable-avdevice',
        '--disable-avformat', '--disable-swscale', '--disable-postproc',
        '--disable-avfilter', '--disable-symver', '--disable-v4l2-m2m',
        '--disable-vulkan', '--enable-swresample',
        '--libdir=' + str(ff / ('android-libs/' + abi)),
        *['--enable-decoder=' + d for d in decoders], cwd=ff)
    run('make', '-j' + JOBS, cwd=ff); run('make', 'install-libs', cwd=ff)
    ffjni = media / 'decoder_ffmpeg/src/main/jni'
    avjni = media / 'decoder_av1/src/main/jni'
    ff_build = WORK / f'ffmpeg-jni-build-{abi}'
    gav1_build = WORK / f'gav1-jni-build-{abi}'
    cmake(ffjni, ff_build, abi)
    cmake(avjni, gav1_build, abi)
    vpx = src['libvpx']
    if (vpx / 'Makefile').exists() or (vpx / 'config.mk').exists():
        subprocess.run(['make', 'distclean'], cwd=vpx, check=False)
    env = dict(os.environ, CC=str(cc), CXX=str(cxx), AR=str(BIN / 'llvm-ar'),
               LD=str(cxx), AS=str(cc) + ' -c', STRIP=str(BIN / 'llvm-strip'))
    run(vpx / 'configure', '--target=' + target['vpx_target'], '--disable-examples',
        '--disable-tools', '--disable-docs', '--disable-unit-tests',
        '--disable-vp8', '--disable-vp9-encoder', '--enable-vp9-highbitdepth',
        '--enable-pic', '--disable-shared', '--enable-static',
        '--disable-runtime-cpu-detect', '--enable-neon', cwd=vpx, env=env)
    run('make', '-j' + JOBS, cwd=vpx, env=env)
    cpu = NDK / 'sources/android/cpufeatures'
    cpu_obj = WORK / f'cpu-features-{abi}.o'
    vpx_so = WORK / f'libvpxV2JNI-{abi}.so'
    run(cc, '-fPIC', '-O2', '-I' + str(cpu), '-c', cpu / 'cpu-features.c', '-o', cpu_obj)
    run(cxx, '-shared', '-fPIC', '-O2', '-std=c++11', '-static-libstdc++',
        '-I' + str(vpx), '-I' + str(cpu), media / 'decoder_vp9/src/main/jni/vpx_jni.cc',
        cpu_obj, vpx / 'libvpx.a', '-llog', '-landroid', '-lz', '-lm',
        PAGE_SIZE_FLAG, '-o', vpx_so)
    out_dir = WORK / f'out-{abi}'
    out_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ff_build / 'libffmpegJNI.so', out_dir / 'libffmpegJNI.so')
    shutil.copy2(gav1_build / 'libgav1JNI.so', out_dir / 'libgav1JNI.so')
    shutil.copy2(vpx_so, out_dir / 'libvpxV2JNI.so')
    libs = [out_dir / 'libffmpegJNI.so', out_dir / 'libgav1JNI.so', out_dir / 'libvpxV2JNI.so']
    for lib in libs:
        run(BIN / 'llvm-strip', '--strip-unneeded', lib)
    return libs

def main():
    WORK.mkdir(exist_ok=True); OUT.mkdir(exist_ok=True)
    src = {name: checkout(name) for name in SOURCES}
    media = src['media'] / 'libraries'
    ff = src['ffmpeg']
    decoders = ['vorbis','opus','flac','alac','pcm_mulaw','pcm_alaw','mp3',
                'amrnb','amrwb','aac','ac3','eac3','dca','mlp','truehd']
    ffjni = media / 'decoder_ffmpeg/src/main/jni'
    from patch_ffmpeg import patch
    patch(ffjni / 'ffmpeg_jni.cc')
    if not (ffjni / 'ffmpeg').exists():
        (ffjni / 'ffmpeg').symlink_to(ff, target_is_directory=True)
    avjni = media / 'decoder_av1/src/main/jni'
    if not (avjni / 'cpu_features').exists():
        (avjni / 'cpu_features').symlink_to(src['cpu_features'], target_is_directory=True)
    if not (avjni / 'libgav1').exists():
        (avjni / 'libgav1').symlink_to(src['libgav1'], target_is_directory=True)
    abseil = src['libgav1'] / 'third_party/abseil-cpp'
    abseil.parent.mkdir(exist_ok=True)
    if abseil.exists() and not abseil.is_symlink() and not any(abseil.iterdir()):
        abseil.rmdir()
    if not abseil.exists():
        abseil.symlink_to(src['abseil'], target_is_directory=True)

    provenance = {
        'sources': SOURCES,
        'patches': ['patch_ffmpeg.py: TrueHD channel layout and flush'],
        'ndk': NDK.name,
        'abis': [t['abi'] for t in TARGETS],
        'api': 23,
        'max_page_size': 16384,
        'audio_decoders': decoders,
        'libraries': {},
    }
    with zipfile.ZipFile(OUT / 'marco-decoders-all.zip', 'w', zipfile.ZIP_DEFLATED) as combined:
        for target in TARGETS:
            abi = target['abi']
            libs = build_abi(target, src, decoders)
            provenance['libraries'][abi] = {}
            zip_path = OUT / f"marco-decoders-{target['zip_suffix']}.zip"
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as archive:
                for lib in libs:
                    provenance['libraries'][abi][lib.name] = hashlib.sha256(lib.read_bytes()).hexdigest()
                    arc = f'lib/{abi}/{lib.name}'
                    archive.write(lib, arc)
                    combined.write(lib, arc)
    (OUT / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    with tarfile.open(OUT / 'marco-decoder-sources.tar.xz', 'w:xz') as archive:
        for name, folder in src.items():
            target = WORK / (name + '-source.tar')
            args = ['git', 'archive', '--format=tar', '--output=' + str(target), 'HEAD']
            if name == 'media':
                args += ['libraries/decoder_ffmpeg','libraries/decoder_av1','libraries/decoder_vp9','LICENSE']
            run(*args, cwd=folder)
            archive.add(target, arcname=name + '-source.tar')
        archive.add(Path(__file__).parent, arcname='build')
        archive.add(OUT / 'provenance.json', arcname='provenance.json')
    for item in list(OUT.iterdir()):
        item.with_name(item.name + '.sha256').write_text(hashlib.sha256(item.read_bytes()).hexdigest() + '  ' + item.name + '\n')

if __name__ == '__main__': main()
