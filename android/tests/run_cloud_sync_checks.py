"""Offline JVM checks for CloudSync v2 (WebDAV, LAN sync, tombstones, and subscription isolation)."""

from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
JDK = Path(os.environ.get("MARCOMOVIE_JDK") or os.environ["JAVA_HOME"]) / "bin"
JAR = ROOT / "android/tests/lib/json-20240303.jar"
SUFFIX = ".exe" if os.name == "nt" else ""

SOURCES = [
    ROOT / "shared/java/com/pilipala/source/Warehouse.java",
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
            str(JAR),
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
            out + os.pathsep + str(JAR),
            "com.pilipala.marcomovie.CloudSyncChecks",
        ],
        check=True,
    )
