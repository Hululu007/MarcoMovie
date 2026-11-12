"""Offline JVM checks for CloudSync v2 (WebDAV, LAN sync, tombstones, and subscription isolation)."""

from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get("MARCOMOVIE_JDK") or os.environ["JAVA_HOME"]) / "bin"
JSON_JAR = ROOT / "android/tests/lib/json-20240303.jar"
OKHTTP_JAR = ROOT / "tools/java-dependencies/okhttp-3.14.9.jar"
OKIO_JAR = ROOT / "tools/java-dependencies/okio-1.17.2.jar"
CLASSPATH = os.pathsep.join([str(JSON_JAR), str(OKHTTP_JAR), str(OKIO_JAR)])
SUFFIX = ".exe" if os.name == "nt" else ""

SOURCES = [
    ROOT / "shared/java/com/pilipala/source/Warehouse.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/AppLog.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/Cms.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/RequestScope.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/Favorites.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/WatchHistory.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/ConfigLibrary.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/ConfigTransferServer.java",
    ROOT / "android/src/main/java/com/pilipala/marcomovie/CloudSync.java",
    ROOT / "android/tests/CloudSyncChecks.java",
]

with tempfile.TemporaryDirectory() as out:
    subprocess.run(
        [
            str(JDK / ("javac" + SUFFIX)),
            "-encoding",
            "UTF-8",
            "-cp",
            CLASSPATH,
            "-d",
            out,
            *map(str, SOURCES),
        ],
        check=True,
    )
    subprocess.run(
        [
            str(JDK / ("java" + SUFFIX)),
            "-cp",
            out + os.pathsep + CLASSPATH,
            "com.pilipala.marcomovie.CloudSyncChecks",
        ],
        check=True,
    )
