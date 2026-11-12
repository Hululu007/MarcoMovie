"""Runner for Android TV/Mobile Conformance Test Suite (Lane H).

Compiles production Cms and related classes with ConformanceChecks.java
against Android SDK compile stubs (android.jar) and executes on pure JVM
using json-20240303.jar for runtime JSON parsing.
"""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK', os.environ.get('JAVA_HOME', 'missing-jdk')))

def ensure_json_jar() -> Path:
    env_jar = os.environ.get('MARCOMOVIE_JSON_JAR')
    if env_jar and Path(env_jar).exists():
        return Path(env_jar)
    jar = ROOT / 'android/tests/lib/json-20240303.jar'
    expected_sha256 = '3cf6cd6892e32e2b4c1c39e0f52f5248a2f5b37646fdfbb79a66b46b618414ed'
    if not jar.exists():
        jar.parent.mkdir(parents=True, exist_ok=True)
        url = 'https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar'
        with urllib.request.urlopen(url, timeout=30) as resp:
            jar.write_bytes(resp.read())
    if hashlib.sha256(jar.read_bytes()).hexdigest() != expected_sha256:
        raise RuntimeError('Test JSON library digest mismatch')
    return jar

def ensure_android_jar() -> Path:
    override = os.environ.get('MARCOMOVIE_ANDROID_JAR')
    if override and Path(override).is_file():
        return Path(override)
    local_jar = ROOT / 'tools/android-35/android.jar'
    if local_jar.is_file():
        return local_jar
    sys.path.insert(0, str(ROOT / 'scripts'))
    from prepare_android_platform import prepare
    return prepare()

def main() -> None:
    json_jar = ensure_json_jar()
    android_jar = ensure_android_jar()

    classes_dir = ROOT / 'android/build/conformance-check/classes'
    classes_dir.mkdir(parents=True, exist_ok=True)

    javac = str(JDK / 'bin' / ('javac.exe' if os.name == 'nt' else 'javac'))
    java = str(JDK / 'bin' / ('java.exe' if os.name == 'nt' else 'java'))

    shared_sources = [
        ROOT / 'shared/java/com/pilipala/source/Json.java',
        ROOT / 'shared/java/com/pilipala/source/Warehouse.java',
    ]

    android_src_dir = ROOT / 'android/src/main/java/com/pilipala/marcomovie'
    required_names = [
        'AppLog.java',
        'Cms.java',
        'RequestScope.java',
        'ProxyAddress.java',
    ]
    prod_sources = [android_src_dir / name for name in required_names]

    test_source = ROOT / 'android/tests/ConformanceChecks.java'

    compile_cmd = [
        javac,
        '-encoding', 'UTF-8',
        '-cp', os.pathsep.join([str(json_jar), str(android_jar)]),
        '-d', str(classes_dir),
        *map(str, shared_sources),
        *map(str, prod_sources),
        str(test_source),
    ]

    print('[run_conformance_checks] Compiling ConformanceChecks...')
    subprocess.run(compile_cmd, check=True)

    exec_cp = os.pathsep.join([str(classes_dir), str(json_jar)])
    exec_cmd = [
        java,
        '-Dfile.encoding=UTF-8',
        '-cp', exec_cp,
        'com.pilipala.marcomovie.ConformanceChecks',
        str(ROOT),
    ]

    print('[run_conformance_checks] Executing ConformanceChecks...')
    res = subprocess.run(exec_cmd, capture_output=True, text=True, encoding='utf-8')

    results_file = ROOT / 'android/tests/conformance-results.txt'
    results_file.write_text(res.stdout + ('\nSTDERR:\n' + res.stderr if res.stderr else ''), encoding='utf-8')

    sys.stdout.write(res.stdout)
    if res.returncode != 0:
        sys.stderr.write(res.stderr)
        sys.exit(res.returncode)

if __name__ == '__main__':
    main()
