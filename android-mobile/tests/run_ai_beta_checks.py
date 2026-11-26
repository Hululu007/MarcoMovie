"""Pure-JVM + local mock HTTP verification suite for Marco Movie AI Beta Lab."""

from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
from android_compile_support import SUFFIX, compile_real_android_sources, resolve_jdk_bin
import gen_ai_beta_code as codegen

ROOT = Path(__file__).resolve().parents[2]
JDK = resolve_jdk_bin()

EXTRA_STUBS = {
    "android/os/Build.java": """package android.os;
public class Build {
    public static class VERSION {
        public static final int SDK_INT = 35;
    }
}
""",
    "android/text/TextUtils.java": """package android.text;
public final class TextUtils {
    public static boolean isEmpty(CharSequence str) {
        return str == null || str.length() == 0;
    }
}
""",
}


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ai-beta-lab-checks-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"

        # 1. Generate ephemeral ECDSA P-256 test keypair & mint test passcodes in Python
        priv_int, pub_bytes = codegen.generate_keypair()
        pub_hex = pub_bytes.hex()
        shared_code = codegen.encode_passcode(
            priv_int,
            batch_id=101,
            expire_day=60,
            flags=codegen.FLAG_CORE_AI | codegen.FLAG_SHARED_CHANNEL,
            min_version_code=103,
        )
        exp_code = codegen.encode_passcode(
            priv_int,
            batch_id=202,
            expire_day=0,
            flags=codegen.FLAG_CORE_AI | codegen.FLAG_EXPERIMENTAL_OAUTH,
            min_version_code=103,
        )
        high_min_vc_code = codegen.encode_passcode(
            priv_int,
            batch_id=303,
            expire_day=0,
            flags=codegen.FLAG_CORE_AI,
            min_version_code=999,
        )
        expired_code = codegen.encode_passcode(
            priv_int,
            batch_id=404,
            expire_day=1,
            flags=codegen.FLAG_CORE_AI,
            min_version_code=103,
        )

        # If the local author private key exists, also verify cross-language against embedded public key
        real_author_code = ""
        author_key_path = ROOT / "android-mobile" / "private" / "ai_beta_signing.key"
        if author_key_path.exists():
            author_priv, _ = codegen._load_key_file(author_key_path)
            real_author_code = codegen.encode_passcode(
                author_priv,
                batch_id=1,
                expire_day=0,
                flags=codegen.FLAG_CORE_AI | codegen.FLAG_SHARED_CHANNEL,
                min_version_code=103,
            )

        runtime_cp = compile_real_android_sources(
            classes_dir=classes_dir,
            work_dir=work_dir,
            test_sources=[ROOT / "android-mobile/tests/AiBetaLabChecks.java"],
            extra_runtime_stubs=EXTRA_STUBS,
        )
        cmd = [
            str(JDK / ("java" + SUFFIX)),
            "-Dfile.encoding=UTF-8",
            "-cp",
            os.pathsep.join(str(p) for p in runtime_cp),
            "com.pilipala.marcomovie.AiBetaLabChecks",
            str(ROOT),
            pub_hex,
            shared_code,
            exp_code,
            high_min_vc_code,
            expired_code,
        ]
        if real_author_code:
            cmd.append(real_author_code)
        subprocess.run(cmd, cwd=ROOT, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
