"""Pure-JVM + local mock HTTP + 3-way Python/Phone-JS/Java ECDSA verification suite."""

from pathlib import Path
import json
import os
import re
import shutil
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


def run_phone_js_roundtrip(
    work_dir: Path, priv_int: int, pub_bytes: bytes, shared_code_from_python: str
) -> dict:
    """Tests scripts/ai_beta_phone_keygen.html crypto & encrypted vault directly in Node.js."""
    node = shutil.which("node")
    if not node:
        # Fallback to Python-encoded vectors if node is absent in an isolated CI container
        return {
            "jsAllPlatCode": codegen.encode_passcode(
                priv_int, batch_id=501, expire_day=60, flags=0x01 | 0x04, min_version_code=0
            ),
            "jsIosOnlyCode": codegen.encode_passcode(
                priv_int, batch_id=502, expire_day=60, flags=0x01 | 0x20, min_version_code=0
            ),
            "jsAndWinCode": codegen.encode_passcode(
                priv_int,
                batch_id=503,
                expire_day=60,
                flags=0x01 | 0x10 | 0x40,
                min_version_code=0,
            ),
        }

    html = (ROOT / "scripts" / "ai_beta_phone_keygen.html").read_text(encoding="utf-8")
    m = re.search(r"<script>([\s\S]*?)</script>", html)
    assert m, "Missing <script> block in ai_beta_phone_keygen.html"
    js_mod = work_dir / "phone_crypto.cjs"
    js_mod.write_text(m.group(1), encoding="utf-8")

    # Encrypt vault in Python -> decrypt in Phone JS (tests PBKDF2-SHA256 + Encrypt-then-MAC!)
    vault = codegen.encrypt_mobile_vault(priv_int, pub_bytes, "marco-test-pwd-99")
    vault_file = work_dir / "vault.json"
    vault_file.write_text(json.dumps(vault), encoding="utf-8")

    driver = work_dir / "driver.cjs"
    driver.write_text(
        """
const fs = require("fs");
const cryptoMod = require(process.argv[2]);
const vault = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const pyCode = process.argv[4];

// 1. Wrong password must fail
let wrongFailed = false;
try { cryptoMod.decryptVault(vault, "wrong-pwd"); } catch (_) { wrongFailed = true; }
if (!wrongFailed) throw new Error("Phone JS vault accepted wrong password!");

// 2. Decrypt Python-encrypted vault
const { privBig, pubBytes } = cryptoMod.decryptVault(vault, "marco-test-pwd-99");
const pubHex = cryptoMod.bytesToHex(pubBytes);

// 3. Verify Python-signed code inside Phone JS
const pyCheck = cryptoMod.verifyPasscode(pyCode, pubHex);
if (!pyCheck.valid || pyCheck.batchId !== 101) {
  throw new Error("Phone JS failed to verify Python-signed code: " + JSON.stringify(pyCheck));
}

// 4. Mint 3 codes inside Phone JS (all-platforms, iOS-only, Android+Windows)
const jsAllPlatCode = cryptoMod.encodePasscode(privBig, { batchId: 501, expireDay: 60, flags: 0x01 | 0x04, minVersionCode: 0 });
const jsIosOnlyCode = cryptoMod.encodePasscode(privBig, { batchId: 502, expireDay: 60, flags: 0x01 | 0x20, minVersionCode: 0 });
const jsAndWinCode = cryptoMod.encodePasscode(privBig, { batchId: 503, expireDay: 60, flags: 0x01 | 0x10 | 0x40, minVersionCode: 0 });

// 5. Re-encrypt vault in Phone JS and confirm decrypt
const reVault = cryptoMod.encryptVault(privBig, pubBytes, "js-pwd-2026", 10000);
const reDec = cryptoMod.decryptVault(reVault, "js-pwd-2026");
if (reDec.privBig !== privBig) throw new Error("Phone JS vault roundtrip failed");

console.log(JSON.stringify({ jsAllPlatCode, jsIosOnlyCode, jsAndWinCode, reVault }));
""",
        encoding="utf-8",
    )
    proc = subprocess.run(
        [node, str(driver), str(js_mod), str(vault_file), shared_code_from_python],
        capture_output=True,
        text=True,
        check=True,
    )
    out = json.loads(proc.stdout.strip())
    # Verify Phone-JS re-encrypted vault decrypts in Python!
    py_priv, _ = codegen.decrypt_mobile_vault(out["reVault"], "js-pwd-2026")
    assert py_priv == priv_int, "Python failed to decrypt Phone-JS encrypted vault!"
    # Verify all 3 Phone-JS minted codes in Python!
    for key in ("jsAllPlatCode", "jsIosOnlyCode", "jsAndWinCode"):
        info = codegen.decode_and_verify_passcode(out[key], pub_bytes)
        assert info["valid_signature"], f"Python failed to verify {key}"
    print("PASS Phone-JS <-> Python 2-way encrypted vault & ECDSA P-256 cross-check")
    return out


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ai-beta-lab-checks-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"

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

        js_res = run_phone_js_roundtrip(work_dir, priv_int, pub_bytes, shared_code)

        real_author_code = ""
        author_key_path = ROOT / "android-mobile" / "private" / "ai_beta_signing.key"
        if author_key_path.exists():
            author_priv, _ = codegen._load_key_file(author_key_path)
            real_author_code = codegen.encode_passcode(
                author_priv,
                batch_id=1,
                expire_day=0,
                flags=codegen.FLAG_CORE_AI | codegen.FLAG_SHARED_CHANNEL,
                min_version_code=0,
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
            js_res["jsAllPlatCode"],
            js_res["jsIosOnlyCode"],
            js_res["jsAndWinCode"],
        ]
        if real_author_code:
            cmd.append(real_author_code)
        subprocess.run(cmd, cwd=ROOT, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
