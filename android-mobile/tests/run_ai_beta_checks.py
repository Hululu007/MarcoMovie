"""Pure-JVM + local mock HTTP + 3-way Python/Phone-JS/Java Ed25519 MMAILAB1 verification suite."""

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
    work_dir: Path, seed: bytes, pub_bytes: bytes, shared_code_from_python: str
) -> dict:
    """Tests scripts/ai_beta_phone_keygen.html Ed25519 crypto & encrypted vault directly in Node.js."""
    base_epoch = 1768000000
    node = shutil.which("node")
    if not node:
        return {
            "jsAllPlatCode": codegen.encode_passcode(
                seed, tag="js-all-501", days=60, platforms="all", shared=True, now_epoch=base_epoch
            ),
            "jsIosOnlyCode": codegen.encode_passcode(
                seed, tag="js-ios-502", days=60, platforms="ios", now_epoch=base_epoch
            ),
            "jsAndWinCode": codegen.encode_passcode(
                seed, tag="js-aw-503", days=60, platforms="android,windows", now_epoch=base_epoch
            ),
        }

    html = (ROOT / "scripts" / "ai_beta_phone_keygen.html").read_text(encoding="utf-8")
    m = re.search(r"<script>([\s\S]*?)</script>", html)
    assert m, "Missing <script> block in ai_beta_phone_keygen.html"
    js_mod = work_dir / "phone_ed25519.cjs"
    js_mod.write_text(m.group(1), encoding="utf-8")

    # Encrypt Ed25519 seed vault in Python -> decrypt in Phone JS
    vault = codegen.encrypt_mobile_vault(seed, pub_bytes, "marco-ed-pwd-99")
    vault_file = work_dir / "vault.json"
    vault_file.write_text(json.dumps(vault), encoding="utf-8")

    driver = work_dir / "driver.cjs"
    driver.write_text(
        """
const fs = require("fs");
const edMod = require(process.argv[2]);
const vault = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const pyCode = process.argv[4];
const baseEpoch = 1768000000;

let wrongFailed = false;
try { edMod.decryptVault(vault, "wrong-pwd"); } catch (_) { wrongFailed = true; }
if (!wrongFailed) throw new Error("Phone JS vault accepted wrong password!");

const { seed, pub } = edMod.decryptVault(vault, "marco-ed-pwd-99");
const pubHex = edMod.bytesToHex(pub);

const pyCheck = edMod.verifyPasscode(pyCode, pubHex);
if (!pyCheck.valid || !pyCheck.claims || pyCheck.claims.tag !== "channel-101") {
  throw new Error("Phone JS failed to verify Python Ed25519 code: " + JSON.stringify(pyCheck));
}

const jsAllPlatCode = edMod.encodePasscode(seed, { tag: "js-all-501", days: 60, plat: "all", shared: true, nowEpochSec: baseEpoch });
const jsIosOnlyCode = edMod.encodePasscode(seed, { tag: "js-ios-502", days: 60, plat: "ios", nowEpochSec: baseEpoch });
const jsAndWinCode = edMod.encodePasscode(seed, { tag: "js-aw-503", days: 60, plat: "android,windows", nowEpochSec: baseEpoch });

const reVault = edMod.encryptVault(seed, pub, "js-ed-pwd-2026", 10000);
const reDec = edMod.decryptVault(reVault, "js-ed-pwd-2026");
if (edMod.bytesToHex(reDec.seed) !== edMod.bytesToHex(seed)) throw new Error("Phone JS vault roundtrip failed");

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
    py_seed, _ = codegen.decrypt_mobile_vault(out["reVault"], "js-ed-pwd-2026")
    assert py_seed == seed, "Python failed to decrypt Phone-JS Ed25519 vault!"
    for key in ("jsAllPlatCode", "jsIosOnlyCode", "jsAndWinCode"):
        info = codegen.decode_and_verify_passcode(out[key], pub_bytes)
        assert info["valid_signature"], f"Python failed to verify {key}"
    print("PASS Phone-JS <-> Python 2-way encrypted Ed25519 vault & MMAILAB1 cross-check")
    return out


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ai-beta-lab-checks-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"
        base_epoch = 1768000000

        seed, pub_bytes = codegen.generate_seed_keypair()
        pub_hex = pub_bytes.hex()
        shared_code = codegen.encode_passcode(
            seed,
            tag="channel-101",
            days=60,
            platforms="all",
            shared=True,
            min_version_code=103,
            now_epoch=base_epoch,
        )
        exp_code = codegen.encode_passcode(
            seed,
            tag="core-202",
            days=0,
            platforms="all",
            shared=False,
            experimental_oauth=True,
            min_version_code=103,
            now_epoch=base_epoch,
        )
        high_min_vc_code = codegen.encode_passcode(
            seed,
            tag="vc-303",
            days=0,
            platforms="all",
            min_version_code=999,
            now_epoch=base_epoch,
        )
        expired_code = codegen.encode_passcode(
            seed,
            tag="exp-404",
            days=1,
            platforms="all",
            now_epoch=base_epoch,
        )

        js_res = run_phone_js_roundtrip(work_dir, seed, pub_bytes, shared_code)

        # Also cross-check against the author's real unified Ed25519 private key if present locally
        real_author_code = ""
        key_path = codegen._default_key_path()
        if key_path.exists():
            real_seed, real_pub = codegen.read_ed25519_seed(key_path)
            if real_pub.hex() == codegen.DEFAULT_PUBKEY_HEX:
                real_author_code = codegen.encode_passcode(
                    real_seed, tag="real-unified-check", days=30, platforms="all", shared=True
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
