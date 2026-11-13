"""Pure JVM checks for Lane E: Performance, Stability, Redirects, UA, and Turkish Locale (§ E1–E5)."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from java_dependencies import ensure_json_jar

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get('MARCOMOVIE_JDK') or os.environ.get('JAVA_HOME', 'missing-jdk'))
SUFFIX = '.exe' if os.name == 'nt' else ''
JSON_JAR = ensure_json_jar()

SOURCES = [
    ROOT / 'shared/java/com/pilipala/source/Json.java',
    ROOT / 'shared/java/com/pilipala/source/Warehouse.java',
    ROOT / 'android/src/main/java/com/pilipala/marcomovie/AppLog.java',
    ROOT / 'android/src/main/java/com/pilipala/marcomovie/Cms.java',
    ROOT / 'android/src/main/java/com/pilipala/marcomovie/RequestScope.java',
    ROOT / 'android/src/main/java/com/pilipala/marcomovie/WatchHistory.java',
    ROOT / 'android/src/main/java/com/pilipala/marcomovie/ConfigStore.java',
    ROOT / 'android/src/main/java/com/pilipala/marcomovie/ConfigLibrary.java',
    ROOT / 'android/tests/LaneEChecks.java',
]

with tempfile.TemporaryDirectory(prefix='lane-e-checks-') as out:
    subprocess.run([
        str(JDK / ('bin/javac' + SUFFIX)),
        '-encoding', 'UTF-8',
        '-source', '8', '-target', '8', '-Xlint:-options',
        '-cp', str(JSON_JAR),
        '-d', out,
        *map(str, SOURCES)
    ], check=True)
    subprocess.run([
        str(JDK / ('bin/java' + SUFFIX)),
        '-Dfile.encoding=UTF-8',
        '-cp', out + os.pathsep + str(JSON_JAR),
        'com.pilipala.marcomovie.LaneEChecks'
    ], cwd=ROOT, check=True)
