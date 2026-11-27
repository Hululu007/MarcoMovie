"""Pure-JVM + local mock HTTP + 3-way Python/Phone-JS/Java Ed25519 MMAILAB1 verification suite.

Hygiene rules enforced (P1-1, P1-6, P2-1):
- NEVER reads or signs with the author's production private key (`private/ai-lab-ed25519.key`).
  Uses ephemeral test seeds plus a fixed non-authorizable expired test vector.
- Verifies released Windows 0.7.3 single-platform rules alongside Android Java verifier on the
  EXACT same signed token vectors.
- Reports explicitly when Node.js is absent (never silently fakes Phone-JS passes).
"""

from pathlib import Path
import argparse
import base64
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
import sign_manifest as ed

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

# Fixed non-authorizable test vector (ephemeral test seed 0x01*32, expired in 2020 -> cannot unlock
# any production app whose embedded pubkey is DEFAULT_PUBKEY_HEX and clock is > 2020).
FIXED_TEST_SEED = bytes([0x11]) * 32
FIXED_TEST_PUB = ed.public_key_from_seed(FIXED_TEST_SEED)
FIXED_NON_AUTH_EXPIRED_TOKEN = codegen.encode_passcode(
    FIXED_TEST_SEED,
    tag="fixed-expired-vector",
    days=1,
    platforms="all",
    now_epoch=1577836800,  # 2020-01-01 UTC -> expired
    nonce="deadbeef",
)


def windows_073_verify(code: str, pub_bytes: bytes, now_epoch: int) -> tuple[bool, str]:
    """Exact mirror of released Windows 0.7.3 verifier (`a11deb29:flutter/lib/core/ai_lab_passcode.dart`).

    Crucially:
    1. `extractToken()` tries direct regex on raw text FIRST (so wrapping inside the 86-char
       signature truncates at the newline and fails verification!).
    2. `matchesPlatform('windows')` accepts ONLY `""`, `"all"`, or exact `"windows"`
       (NO comma combinations) and ignores `min_vc`.
    """
    trimmed = (code or "").strip()
    if not trimmed:
        return False, "empty"
    m = re.search(r"MMAILAB1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)", trimmed)
    if not m:
        collapsed = "".join(trimmed.split())
        m = re.search(r"MMAILAB1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)", collapsed)
    if not m:
        return False, "malformed"
    try:
        payload_bytes = codegen._b64url_decode(m.group(1))
        sig = codegen._b64url_decode(m.group(2))
    except Exception:
        return False, "malformed"
    if len(sig) != 64 or not ed.verify(pub_bytes, codegen.SIGN_DOMAIN + payload_bytes, sig):
        return False, "invalidSignature"
    claims = json.loads(payload_bytes.decode("utf-8"))
    if claims.get("v") != 1:
        return False, "unsupportedVersion"
    plat = str(claims.get("plat", "all") or "").strip().lower()
    if plat not in ("", "all", "windows"):
        return False, "wrongPlatform"
    exp = int(claims.get("exp", 0) or 0)
    if exp > 0 and now_epoch > exp:
        return False, "expired"
    return True, "valid"


def verify_python_issuance_rules(seed: bytes, pub_bytes: bytes, base_epoch: int) -> None:
    """Tests P1-1 & P2-1 issuance constraints in scripts/gen_ai_beta_code.py."""
    # 1. Multi-platform request MUST split into separate single-platform codes, NEVER comma-joined or 'all'
    try:
        codegen.encode_passcode(
            seed, tag="bad-combo", days=30, platforms="android,windows", now_epoch=base_epoch
        )
        raise AssertionError("encode_passcode allowed comma-combined plat='android,windows'")
    except ValueError:
        pass

    split_items = codegen.issue_passcodes(
        seed, tag="split-aw", days=30, platforms="android,windows", count=2, now_epoch=base_epoch
    )
    assert len(split_items) == 4, f"Expected 2 platforms x 2 codes = 4, got {len(split_items)}"
    plats = [it["platform"] for it in split_items]
    assert plats == ["android", "android", "windows", "windows"], f"Unexpected split plats: {plats}"
    assert len({it["token"] for it in split_items}) == 4, "Batch deduplication failed"
    for it in split_items:
        win_ok, _ = windows_073_verify(it["token"], pub_bytes, base_epoch + 10)
        if it["platform"] == "windows":
            assert win_ok, "Windows targeted token rejected by Windows 0.7.3 verifier"
        else:
            assert not win_ok, "Android targeted token unexpectedly accepted by Windows 0.7.3 verifier"

    # 2. min_vc > 0 MUST be rejected for all/windows/ios and allowed ONLY for android
    for forbidden_plat in ("all", "windows", "ios"):
        try:
            codegen.encode_passcode(
                seed,
                tag="bad-minvc",
                days=30,
                platforms=forbidden_plat,
                min_version_code=103,
                now_epoch=base_epoch,
            )
            raise AssertionError(f"min_vc>0 allowed on {forbidden_plat}")
        except ValueError:
            pass

    # 3. Blank / 0 / negative days cannot silently become permanent
    for bad_days in (None, 0, -7, 3651):
        try:
            codegen.encode_passcode(
                seed, tag="bad-days", days=bad_days, never_expire=False, platforms="all", now_epoch=base_epoch
            )
            raise AssertionError(f"days={bad_days} silently succeeded without never_expire=True")
        except ValueError:
            pass

    # 4. Wrapped signature extraction + signatureValid vs platform activatability distinction
    and_only = split_items[0]["token"]
    dot1 = and_only.index(".")
    dot2 = and_only.index(".", dot1 + 1)
    wrapped = (
        "内测口令：\n"
        + and_only[: dot2 + 25]
        + "\n"
        + and_only[dot2 + 25 :]
        + "\nTrailing ASCII note 2026"
    )
    info = codegen.decode_and_verify_passcode(
        wrapped, pub_bytes, now_epoch=base_epoch + 10, target_platform="windows"
    )
    assert info["valid_signature"] is True
    assert info["activatable_by_platform"]["android"]["ok"] is True
    assert info["activatable_by_platform"]["windows"]["ok"] is False
    assert info["activatable_for_target"] is False

    # 5. P2-2: min_vc=65535 MUST NOT report activatable when target app_version_code is omitted,
    #    rejects candidate 103, and accepts 65535. Also verify Windows 0.7.3 wrapped-sig limitation.
    max_vc_token = codegen.encode_passcode(
        seed, tag="max-vc", days=30, platforms="android", min_version_code=65535, now_epoch=base_epoch
    )
    no_vc_info = codegen.decode_and_verify_passcode(
        max_vc_token, pub_bytes, now_epoch=base_epoch + 10, target_platform="android"
    )
    assert no_vc_info["valid_signature"] is True
    assert no_vc_info["activatable_by_platform"]["android"]["ok"] is False
    assert no_vc_info["activatable_by_platform"]["android"]["status"] == "unknown_version"
    assert no_vc_info["activatable_for_target"] is False
    vc103_info = codegen.decode_and_verify_passcode(
        max_vc_token,
        pub_bytes,
        now_epoch=base_epoch + 10,
        target_platform="android",
        app_version_code=103,
    )
    assert vc103_info["activatable_by_platform"]["android"]["ok"] is False
    assert vc103_info["activatable_by_platform"]["android"]["status"] == "version_too_low"
    vc65535_info = codegen.decode_and_verify_passcode(
        max_vc_token,
        pub_bytes,
        now_epoch=base_epoch + 10,
        target_platform="android",
        app_version_code=65535,
    )
    assert vc65535_info["activatable_by_platform"]["android"]["ok"] is True

    # Windows 0.7.3 rejects signature-wrapped tokens (single-line required for Windows 0.7.3)
    win_tok = [it["token"] for it in split_items if it["platform"] == "windows"][0]
    w_dot2 = win_tok.rindex(".")
    win_wrapped_sig = win_tok[: w_dot2 + 20] + "\n" + win_tok[w_dot2 + 20 :]
    assert windows_073_verify(win_tok, pub_bytes, base_epoch + 10)[0] is True
    assert windows_073_verify(win_wrapped_sig, pub_bytes, base_epoch + 10)[0] is False

    # 6. Fixed non-authorizable expired test vector verifies signature but is non-activatable everywhere
    fixed_info = codegen.decode_and_verify_passcode(
        FIXED_NON_AUTH_EXPIRED_TOKEN, FIXED_TEST_PUB, now_epoch=base_epoch
    )
    assert fixed_info["valid_signature"] is True and fixed_info["expired"] is True
    assert all(not fixed_info["activatable_by_platform"][p]["ok"] for p in ("android", "ios", "windows"))
    assert FIXED_TEST_PUB.hex() != codegen.DEFAULT_PUBKEY_HEX
    print("PASS Python issuance constraints (split multi-plat, min_vc version guard, strict expiry, wrapped sig)")


def run_phone_js_roundtrip(
    work_dir: Path,
    seed: bytes,
    pub_bytes: bytes,
    shared_code_from_python: str,
    require_node: bool,
) -> dict:
    """Tests scripts/ai_beta_phone_keygen.html Ed25519 crypto, XSS/ledger/pubkey guards & rules in Node.js."""
    base_epoch = 1768000000
    html_path = ROOT / "scripts" / "ai_beta_phone_keygen.html"
    html = html_path.read_text(encoding="utf-8")

    # Static P1-3, P1-5, P1-6 & P2-1 hygiene checks on phone keygen HTML (always executed)
    assert ".innerHTML" not in html, "Security P1-6: ai_beta_phone_keygen.html must not use innerHTML"
    assert "Math.random" not in html, "Security P2-1: ai_beta_phone_keygen.html must not fall back to Math.random"
    assert "contains_usable_passcodes: false" in html, "Security P1-6: exported ledger must explicitly exclude usable passcodes"
    assert "isOfficialPublicKey" in html, "Security P1-6: phone keygen must check pinned official public key"
    assert "activeSeed.fill(0)" in html, "Security P1-6: lockVault must scrub activeSeed in memory"
    assert "clearFileInput()" in html and "scrubPendingImport()" in html, "Security P1-5: phone keygen must release file input and scrub pending seed"
    assert 'id="expChk"' not in html, "P1-3: phone keygen must not advertise withdrawn experimental OpenAI OAuth"

    node = shutil.which("node")
    if not node:
        msg = "WARN: Node.js not found in PATH — Phone-JS runtime tests were NOT executed!"
        if require_node:
            raise RuntimeError(msg)
        print(msg, file=sys.stderr)
        return {
            "nodeExecuted": False,
            "jsAllPlatCode": codegen.encode_passcode(
                seed, tag="js-all-501", days=60, platforms="all", shared=True, now_epoch=base_epoch
            ),
            "jsIosOnlyCode": codegen.encode_passcode(
                seed, tag="js-ios-502", days=60, platforms="ios", now_epoch=base_epoch
            ),
            "jsWinOnlyCode": codegen.encode_passcode(
                seed, tag="js-win-503", days=60, platforms="windows", now_epoch=base_epoch
            ),
        }

    m = re.search(r"<script>([\s\S]*?)</script>", html)
    assert m, "Missing <script> block in ai_beta_phone_keygen.html"
    js_mod = work_dir / "phone_ed25519.cjs"
    js_mod.write_text(m.group(1), encoding="utf-8")

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

if (edMod.isOfficialPublicKey(pubHex)) {
  throw new Error("Ephemeral test pubkey must NOT match pinned official pubkey!");
}
if (!edMod.isOfficialPublicKey(edMod.DEFAULT_PUB_HEX)) {
  throw new Error("Pinned DEFAULT_PUB_HEX failed official check!");
}

const pyCheck = edMod.verifyPasscode(pyCode, pubHex, { nowEpochSec: baseEpoch + 10 });
if (!pyCheck.signatureValid || !pyCheck.activatable.android.ok || !pyCheck.activatable.windows.ok) {
  throw new Error("Phone JS failed to verify Python Ed25519 code: " + JSON.stringify(pyCheck));
}

// Reject comma-combined plat in encodePasscode
let comboRejected = false;
try { edMod.encodePasscode(seed, { tag: "bad", days: 30, plat: "android,windows", nowEpochSec: baseEpoch }); } catch (_) { comboRejected = true; }
if (!comboRejected) throw new Error("Phone JS allowed comma-combined plat!");

// Reject minVc > 0 for all/windows/ios
for (const p of ["all", "windows", "ios"]) {
  let rej = false;
  try { edMod.encodePasscode(seed, { tag: "bad", days: 30, plat: p, minVc: 103, nowEpochSec: baseEpoch }); } catch (_) { rej = true; }
  if (!rej) throw new Error("Phone JS allowed minVc > 0 for " + p);
}

// Reject blank / 0 / negative days when neverExpire is false
for (const d of ["", " ", 0, -5, 3651, "abc"]) {
  let rej = false;
  try { edMod.encodePasscode(seed, { tag: "bad", days: d, neverExpire: false, plat: "all", nowEpochSec: baseEpoch }); } catch (_) { rej = true; }
  if (!rej) throw new Error("Phone JS silently accepted invalid days=" + JSON.stringify(d));
}

// Multi-platform issueBatch splits into per-platform targeted codes without widening to 'all'
const splitBatch = edMod.issueBatch(seed, pubHex, {
  tag: "js-split", days: 30, platforms: ["android", "windows"], count: 3, nowEpochSec: baseEpoch
});
if (splitBatch.targets.join(",") !== "android,windows" || splitBatch.items.length !== 6) {
  throw new Error("Phone JS multi-platform split failed: " + JSON.stringify(splitBatch.targets));
}
const uniq = new Set(splitBatch.items.map(x => x.code));
if (uniq.size !== 6) throw new Error("Phone JS batch deduplication failed");
for (const it of splitBatch.items) {
  if (it.fingerprint.includes(it.code)) throw new Error("Fingerprint leaked full token!");
}

const jsAllPlatCode = edMod.encodePasscode(seed, { tag: "js-all-501", days: 60, plat: "all", shared: true, nowEpochSec: baseEpoch });
const jsIosOnlyCode = edMod.encodePasscode(seed, { tag: "js-ios-502", days: 60, plat: "ios", nowEpochSec: baseEpoch });
const jsWinOnlyCode = edMod.encodePasscode(seed, { tag: "js-win-503", days: 60, plat: "windows", nowEpochSec: baseEpoch });

// Wrapped signature + trailing prose extraction & signatureValid vs activatable distinction
const dot2 = jsIosOnlyCode.lastIndexOf(".");
const wrappedIos = "说明：\\n" + jsIosOnlyCode.slice(0, dot2 + 20) + "\\n" + jsIosOnlyCode.slice(dot2 + 20) + "\\nNote trailing English";
const wrappedChk = edMod.verifyPasscode(wrappedIos, pubHex, { nowEpochSec: baseEpoch + 10, targetPlatform: "windows" });
if (!wrappedChk.signatureValid || !wrappedChk.activatable.ios.ok || wrappedChk.activatable.windows.ok || wrappedChk.activatableForTarget) {
  throw new Error("Phone JS wrapped-sig / activatable distinction failed: " + JSON.stringify(wrappedChk));
}

const reVault = edMod.encryptVault(seed, pub, "js-ed-pwd-2026", 10000);
const reDec = edMod.decryptVault(reVault, "js-ed-pwd-2026");
if (edMod.bytesToHex(reDec.seed) !== edMod.bytesToHex(seed)) throw new Error("Phone JS vault roundtrip failed");

// P2-2: min_vc=65535 MUST NOT report activatable when appVersionCode is missing, rejects 103, accepts 65535
const highVcCode = edMod.encodePasscode(seed, { tag: "vc-max", days: 30, plat: "android", minVc: 65535, nowEpochSec: baseEpoch });
const chkNoVc = edMod.verifyPasscode(highVcCode, pubHex, { nowEpochSec: baseEpoch + 10 });
const chk103 = edMod.verifyPasscode(highVcCode, pubHex, { nowEpochSec: baseEpoch + 10, appVersionCode: 103 });
const chk65535 = edMod.verifyPasscode(highVcCode, pubHex, { nowEpochSec: baseEpoch + 10, appVersionCode: 65535 });
if (!chkNoVc.signatureValid || chkNoVc.activatable.android.ok !== false || chkNoVc.activatable.android.status !== "unknown_version") {
  throw new Error("P2-2: Phone JS reported min_vc=65535 activatable without versionCode: " + JSON.stringify(chkNoVc));
}
if (chk103.activatable.android.ok !== false || chk103.activatable.android.status !== "version_too_low") {
  throw new Error("P2-2: Phone JS did not reject candidate 103 for min_vc=65535");
}
if (chk65535.activatable.android.ok !== true) {
  throw new Error("P2-2: Phone JS rejected exact min_vc=65535");
}

// P1-5: Full DOM lifecycle simulation with ephemeral .key seed -> FileList=0 on import, cancel, fail, and lock!
const vm = require("vm");
const scriptSrc = fs.readFileSync(process.argv[2], "utf8");
function makeClassList(initial = []) {
  const s = new Set(initial);
  return {
    add: (...c) => c.forEach(x => s.add(x)),
    remove: (...c) => c.forEach(x => s.delete(x)),
    toggle: (c, force) => { if (force === undefined) { if (s.has(c)) s.delete(c); else s.add(c); } else if (force) s.add(c); else s.delete(c); },
    contains: (c) => s.has(c),
  };
}
function makeEl(id, extra = {}) {
  const el = {
    id, value: "", textContent: "", checked: false, disabled: false, dataset: {},
    classList: makeClassList(), children: [],
    appendChild(c) { this.children.push(c); return c; },
    ...extra
  };
  return el;
}
const vaultFileEl = makeEl("vaultFile");
let vaultFileList = [];
Object.defineProperty(vaultFileEl, "files", {
  get() { return vaultFileList; },
  set(v) { vaultFileList = Array.from(v || []); }
});
let vaultFileVal = "";
Object.defineProperty(vaultFileEl, "value", {
  get() { return vaultFileVal; },
  set(v) { vaultFileVal = String(v || ""); if (!vaultFileVal) vaultFileList = []; }
});
const els = {
  toast: makeEl("toast"),
  lockBadge: makeEl("lockBadge"),
  lockBtn: makeEl("lockBtn"),
  vaultHint: makeEl("vaultHint"),
  unlockPane: makeEl("unlockPane"),
  unlockPwd: makeEl("unlockPwd"),
  importPane: makeEl("importPane"),
  vaultFile: vaultFileEl,
  rawPwdBox: makeEl("rawPwdBox", { classList: makeClassList(["hidden"]) }),
  newVaultPwd: makeEl("newVaultPwd"),
  issueCard: makeEl("issueCard", { classList: makeClassList(["hidden"]) }),
  ledgerCard: makeEl("ledgerCard", { classList: makeClassList(["hidden"]) }),
  testKeyWarn: makeEl("testKeyWarn", { classList: makeClassList(["hidden"]) }),
  testKeyWarnText: makeEl("testKeyWarnText"),
  allowTestKeyChk: makeEl("allowTestKeyChk"),
  minVcIn: makeEl("minVcIn", { value: "0" }),
  minVcLbl: makeEl("minVcLbl"),
  platModeNotice: makeEl("platModeNotice", { classList: makeClassList(["hidden"]) }),
  neverExpireChk: makeEl("neverExpireChk"),
  tagIn: makeEl("tagIn", { value: "ephem-tag" }),
  daysIn: makeEl("daysIn", { value: "30" }),
  countIn: makeEl("countIn", { value: "1" }),
  noteIn: makeEl("noteIn", { value: "test-note" }),
  sharedChk: makeEl("sharedChk", { checked: true }),
  resultWrap: makeEl("resultWrap", { classList: makeClassList(["hidden"]) }),
  resultMeta: makeEl("resultMeta"),
  resultCodes: makeEl("resultCodes"),
  verifyIn: makeEl("verifyIn"),
  verifyAndroidVcIn: makeEl("verifyAndroidVcIn"),
  verifyOut: makeEl("verifyOut", { classList: makeClassList(["hidden"]) }),
  ledgerList: makeEl("ledgerList"),
};
const lsMap = new Map();
const deferredReaders = [];
class FakeFileReader {
  constructor() {
    this.aborted = false;
    this.result = "";
  }
  abort() {
    this.aborted = true;
    if (this.onabort) this.onabort();
  }
  readAsText(file) {
    if (file && file.defer) {
      this._pendingFile = file;
      deferredReaders.push(this);
      return;
    }
    this._deliver(file);
  }
  _deliver(file) {
    if (file && file.fail) {
      if (this.onerror) this.onerror(new Error("read failed"));
      return;
    }
    this.result = file ? file.content : "";
    if (this.onload) this.onload();
  }
}
const sandbox = {
  console, TextEncoder, TextDecoder, Uint8Array, Uint32Array, DataView, BigInt, JSON, Set, Map, Array, Object, Number, String, Error, Date, Math,
  setTimeout: () => 1, clearTimeout: () => {},
  crypto: require("crypto").webcrypto,
  localStorage: {
    getItem: (k) => lsMap.has(k) ? lsMap.get(k) : null,
    setItem: (k, v) => lsMap.set(k, String(v)),
    removeItem: (k) => lsMap.delete(k),
  },
  FileReader: FakeFileReader,
  document: {
    getElementById: (id) => els[id] || null,
    querySelectorAll: () => [],
    createElement: (tag) => makeEl(tag),
  },
  window: { addEventListener: () => {} },
};
sandbox.globalThis = sandbox;
const ctx = vm.createContext(sandbox);
vm.runInContext(scriptSrc, ctx);
vm.runInContext("initUi();", ctx);

const seedHex = edMod.bytesToHex(seed);
// Step A: Import ephemeral .key file -> FileList MUST become 0 immediately
vaultFileVal = "C:\\fakepath\\ephemeral.key";
vaultFileList = [{ name: "ephemeral.key", content: seedHex }];
vm.runInContext("handleImportFile({ target: document.getElementById('vaultFile') });", ctx);
if (vaultFileEl.files.length !== 0 || vaultFileEl.value !== "") {
  throw new Error("P1-5: FileList not cleared right after .key import!");
}
if (els.rawPwdBox.classList.contains("hidden")) {
  throw new Error("P1-5: rawPwdBox did not open for pending raw seed");
}

// Step B: Cancel import -> pendingRawSeed scrubbed & FileList=0
vm.runInContext("cancelRawImport();", ctx);
if (vm.runInContext("pendingRawSeed !== null", ctx) || vaultFileEl.files.length !== 0 || !els.rawPwdBox.classList.contains("hidden")) {
  throw new Error("P1-5: cancelRawImport failed to clear pendingRawSeed/FileList");
}

// Step C: Failed read / malformed file -> clears pending seed & outputs & FileList=0
vaultFileVal = "C:\\fakepath\\bad.key";
vaultFileList = [{ name: "bad.key", fail: true }];
vm.runInContext("handleImportFile({ target: document.getElementById('vaultFile') });", ctx);
if (vm.runInContext("pendingRawSeed !== null", ctx) || vaultFileEl.files.length !== 0) {
  throw new Error("P1-5: read error left pendingRawSeed or FileList populated");
}

// Step D: Full ephemeral flow -> import -> encrypt & unlock -> issue -> lock -> FileList=0 & all cleared!
vaultFileVal = "C:\\fakepath\\ephemeral2.key";
vaultFileList = [{ name: "ephemeral2.key", content: seedHex }];
vm.runInContext("handleImportFile({ target: document.getElementById('vaultFile') });", ctx);
els.newVaultPwd.value = "ephem-pass-999";
vm.runInContext("finishRawImport();", ctx);
els.allowTestKeyChk.checked = true;
vm.runInContext("issueNow();", ctx);
if (!els.resultCodes.textContent.includes("MMAILAB1.")) {
  throw new Error("P1-5: ephemeral issueNow did not render passcode");
}
vm.runInContext("lockVault();", ctx);
if (
  vaultFileEl.files.length !== 0 ||
  vaultFileEl.value !== "" ||
  vm.runInContext("activeSeed !== null || pendingRawSeed !== null", ctx) ||
  els.resultCodes.textContent !== "" ||
  els.verifyOut.textContent !== "" ||
  els.ledgerList.textContent !== "" ||
  els.unlockPwd.value !== "" ||
  els.newVaultPwd.value !== ""
) {
  throw new Error("P1-5: lockVault failed to clear FileList=0, seeds, passwords, or outputs!");
}

// Step E (Round-4 P1-6): Stale FileReader onload arriving LAST after lockVault() MUST NOT restore pendingRawSeed!
deferredReaders.length = 0;
vaultFileVal = "C:\\fakepath\\slow-lock.key";
vaultFileList = [{ name: "slow-lock.key", content: seedHex, defer: true }];
vm.runInContext("handleImportFile({ target: document.getElementById('vaultFile') });", ctx);
if (deferredReaders.length !== 1) throw new Error("P1-6: expected 1 deferred FileReader for lock test");
const staleLockReader = deferredReaders.shift();
vm.runInContext("lockVault();", ctx);
staleLockReader._deliver({ name: "slow-lock.key", content: seedHex });
if (!staleLockReader.aborted || vm.runInContext("pendingRawSeed !== null", ctx) || !els.rawPwdBox.classList.contains("hidden")) {
  throw new Error("R4 P1-6: stale FileReader after lockVault restored pendingRawSeed!");
}

// Step F (Round-4 P1-6): Stale FileReader onload arriving LAST after cancelRawImport() MUST NOT restore pendingRawSeed!
vaultFileVal = "C:\\fakepath\\slow-cancel.key";
vaultFileList = [{ name: "slow-cancel.key", content: seedHex, defer: true }];
vm.runInContext("handleImportFile({ target: document.getElementById('vaultFile') });", ctx);
const staleCancelReader = deferredReaders.shift();
vm.runInContext("cancelRawImport();", ctx);
staleCancelReader._deliver({ name: "slow-cancel.key", content: seedHex });
if (!staleCancelReader.aborted || vm.runInContext("pendingRawSeed !== null", ctx) || !els.rawPwdBox.classList.contains("hidden")) {
  throw new Error("R4 P1-6: stale FileReader after cancelRawImport restored pendingRawSeed!");
}

// Step G (Round-4 P1-6): Stale FileReader (File A) arriving LAST after user selects newer Vault B MUST NOT overwrite Vault B!
const vaultBJson = JSON.stringify({
  format: "marco-ai-ed25519-vault-v1",
  kdf: "pbkdf2-sha256",
  iterations: 210000,
  salt_b64: "AAAAAAAAAAAAAAAAAAAAAA==",
  nonce_b64: "AAAAAAAAAAAAAAAA",
  ct_b64: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
  mac_b64: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=",
  pub_hex: "11".repeat(32),
});
vaultFileVal = "C:\\fakepath\\old-file-A.key";
vaultFileList = [{ name: "old-file-A.key", content: seedHex, defer: true }];
vm.runInContext("handleImportFile({ target: document.getElementById('vaultFile') });", ctx);
const staleFileAReader = deferredReaders.shift();
vaultFileVal = "C:\\fakepath\\new-vault-B.json";
vaultFileList = [{ name: "new-vault-B.json", content: vaultBJson }];
vm.runInContext("handleImportFile({ target: document.getElementById('vaultFile') });", ctx);
// Now deliver stale File A callback LAST!
staleFileAReader._deliver({ name: "old-file-A.key", content: seedHex });
const savedVaultAfterRace = lsMap.get("marco_ai_ed25519_vault_v1");
if (
  !staleFileAReader.aborted ||
  vm.runInContext("pendingRawSeed !== null", ctx) ||
  !els.rawPwdBox.classList.contains("hidden") ||
  savedVaultAfterRace !== vaultBJson
) {
  throw new Error("R4 P1-6: stale FileReader from File A overwrote newer Vault B or restored pendingRawSeed!");
}

console.log(JSON.stringify({ nodeExecuted: true, jsAllPlatCode, jsIosOnlyCode, jsWinOnlyCode, reVault }));
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
    for key, expected_win in (
        ("jsAllPlatCode", True),
        ("jsIosOnlyCode", False),
        ("jsWinOnlyCode", True),
    ):
        info = codegen.decode_and_verify_passcode(out[key], pub_bytes, now_epoch=base_epoch + 10)
        assert info["valid_signature"], f"Python failed to verify {key}"
        win_ok, _ = windows_073_verify(out[key], pub_bytes, base_epoch + 10)
        assert win_ok == expected_win, f"Windows 0.7.3 verifier mismatch on {key}"
    print("PASS Phone-JS <-> Python <-> Windows-0.7.3 Ed25519 vault & MMAILAB1 cross-check (Node executed)")
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-node", action="store_true", help="Fail if Node.js is unavailable")
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="ai-beta-lab-checks-") as tmp:
        work_dir = Path(tmp)
        classes_dir = work_dir / "classes"
        base_epoch = 1768000000

        seed, pub_bytes = codegen.generate_seed_keypair()
        pub_hex = pub_bytes.hex()

        verify_python_issuance_rules(seed, pub_bytes, base_epoch)

        shared_code = codegen.encode_passcode(
            seed,
            tag="channel-101",
            days=60,
            platforms="all",
            shared=True,
            min_version_code=0,
            now_epoch=base_epoch,
        )
        exp_code = codegen.encode_passcode(
            seed,
            tag="core-202",
            never_expire=True,
            platforms="all",
            shared=False,
            experimental_oauth=True,
            min_version_code=0,
            now_epoch=base_epoch,
        )
        high_min_vc_code = codegen.encode_passcode(
            seed,
            tag="vc-303",
            never_expire=True,
            platforms="android",
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

        # Cross-verify shared & exp codes on released Windows 0.7.3 verifier too
        assert windows_073_verify(shared_code, pub_bytes, base_epoch + 10)[0]
        assert windows_073_verify(exp_code, pub_bytes, base_epoch + 10)[0]
        assert not windows_073_verify(high_min_vc_code, pub_bytes, base_epoch + 10)[0]

        js_res = run_phone_js_roundtrip(work_dir, seed, pub_bytes, shared_code, args.require_node)

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
            js_res["jsWinOnlyCode"],
            FIXED_TEST_PUB.hex(),
            FIXED_NON_AUTH_EXPIRED_TOKEN,
        ]
        subprocess.run(cmd, cwd=ROOT, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
