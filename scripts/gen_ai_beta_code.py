#!/usr/bin/env python3
"""Unified cross-platform (Android Mobile / iOS / Windows) RFC 8032 Ed25519 passcode CLI
and password-encrypted mobile HTML keygen exporter for Marco Movie AI Lab.

Canonical token format (shared with scripts/sign_manifest.py & flutter/lib/core/ai_lab_passcode.dart):
  MMAILAB1.<payload_b64url>.<sig_b64url>
  Signing message: b"marco-ai-lab-v1:" + canonical_json_bytes

Compatibility constraints enforced at issuance (matching released Windows 0.7.3 verifier):
  - Released Windows/Flutter client (`flutter/lib/core/ai_lab_passcode.dart`) accepts ONLY
    `plat == "all"` or a single exact platform (`"android"`, `"ios"`, `"windows"`), and does
    NOT enforce `min_vc`.
  - Therefore official issuance NEVER emits comma-joined `plat` combinations (e.g. "android,windows")
    and NEVER silently widens a multi-platform subset into `"all"`. Instead, passing multiple
    platforms splits issuance into separate per-platform targeted tokens.
  - `min_vc > 0` is ONLY permitted on Android-targeted tokens (`plat == "android"`).

Zero external dependencies (pure Python 3 standard library).
Private key stays strictly local under private/ai-lab-ed25519.key (gitignored).
"""

from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import hmac
import json
import re
import secrets
import struct
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))
import sign_manifest as ed

TOKEN_PREFIX = "MMAILAB1."
SIGN_DOMAIN = b"marco-ai-lab-v1:"
DEFAULT_PUBKEY_HEX = "1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929"
VAULT_PBKDF2_ITERS = 100_000
ED25519_SIG_B64URL_LEN = 86

SINGLE_PLATFORMS = ("android", "ios", "windows")
VALID_TOKEN_PLATFORMS = ("all",) + SINGLE_PLATFORMS
MAX_DAYS = 3650
MAX_COUNT = 50
MAX_MIN_VC = 65535
MAX_TAG_LEN = 48

TEMPLATE_HTML_PATH = SCRIPT_DIR / "ai_beta_phone_keygen.html"
_TOKEN_EXTRACT_RE = re.compile(r"MMAILAB1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)")
_B64URL_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")


def _default_key_path() -> Path:
    candidates = [
        ROOT_DIR / "private" / "ai-lab-ed25519.key",
        ROOT_DIR.parent.parent / "private" / "ai-lab-ed25519.key",
    ]
    for c in candidates:
        if c.exists():
            return c
    return candidates[0]


def _default_private_dir() -> Path:
    return _default_key_path().parent


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(text: str) -> bytes:
    if not text or (len(text) % 4) == 1:
        raise ValueError("Invalid base64url length")
    padded = text + ("=" * ((4 - len(text) % 4) % 4))
    return base64.urlsafe_b64decode(padded.encode("ascii"))


def generate_seed_keypair() -> Tuple[bytes, bytes]:
    seed = secrets.token_bytes(32)
    pub = ed.public_key_from_seed(seed)
    return seed, pub


def read_ed25519_seed(path: Path) -> Tuple[bytes, bytes]:
    seed = ed._read_32byte_key_file(path, "Ed25519 private seed")
    pub = ed.public_key_from_seed(seed)
    return seed, pub


def _scan_wrapped_token(text: str, start: int) -> str:
    pos = start + len(TOKEN_PREFIX)
    n = len(text)
    payload: List[str] = []
    saw_dot = False
    while pos < n:
        ch = text[pos]
        if ch.isspace():
            pos += 1
            continue
        if ch == ".":
            pos += 1
            saw_dot = True
            break
        if ch in _B64URL_CHARS:
            payload.append(ch)
            pos += 1
            continue
        return ""
    if not saw_dot or not payload:
        return ""
    sig: List[str] = []
    while pos < n:
        ch = text[pos]
        if ch.isspace():
            if len(sig) >= ED25519_SIG_B64URL_LEN:
                break
            pos += 1
            continue
        if ch in _B64URL_CHARS:
            sig.append(ch)
            pos += 1
            continue
        break
    if not sig:
        return ""
    return f"{TOKEN_PREFIX}{''.join(payload)}.{''.join(sig)}"


def extract_token(raw: str) -> str:
    """Extracts MMAILAB1.<payload>.<sig> even when wrapped across lines inside payload or sig."""
    trimmed = (raw or "").strip()
    if not trimmed:
        return ""
    for m in _TOKEN_EXTRACT_RE.finditer(trimmed):
        try:
            if len(_b64url_decode(m.group(2))) == 64:
                return m.group(0)
        except Exception:
            pass
    idx = trimmed.find(TOKEN_PREFIX)
    if idx >= 0:
        scanned = _scan_wrapped_token(trimmed, idx)
        if scanned:
            return scanned
    collapsed = "".join(trimmed.split())
    cidx = collapsed.find(TOKEN_PREFIX)
    if cidx >= 0:
        scanned = _scan_wrapped_token(collapsed, cidx)
        if scanned:
            return scanned
    m = _TOKEN_EXTRACT_RE.search(collapsed)
    return m.group(0) if m else collapsed


def _normalize_single_platform(part: str) -> str:
    p = part.strip().lower()
    if p in ("android-mobile", "mobile"):
        return "android"
    if p in ("win", "pc"):
        return "windows"
    if p in ("iphone", "ipad"):
        return "ios"
    return p


def parse_target_platforms(raw: str) -> List[str]:
    """Resolves requested platform option into a list of Windows-0.7.3-compatible token `plat` values.

    - Explicit `"all"` or `"*"` -> `["all"]`
    - Single platform (`"android"`, `"ios"`, `"windows"`) -> `[p]`
    - Multiple individual platforms (e.g. `"android,windows"`) -> split into separate per-platform
      targeted codes `["android", "windows"]`, NEVER comma-joined and NEVER silently widened to `"all"`.
    """
    text = (raw or "").strip().lower()
    if not text:
        raise ValueError("Platform must be specified (use all, android, ios, or windows)")
    if text in ("all", "*"):
        return ["all"]
    seen: List[str] = []
    for part in re.split(r"[,;/\s]+", text):
        p = _normalize_single_platform(part)
        if not p:
            continue
        if p in ("all", "*"):
            raise ValueError("Cannot mix 'all' with individual platforms; pass --platforms all alone")
        if p not in SINGLE_PLATFORMS:
            raise ValueError(f"Unknown platform '{p}' (use all, android, ios, windows)")
        if p not in seen:
            seen.append(p)
    if not seen:
        raise ValueError("No valid platform specified (use all, android, ios, windows)")
    return seen


def validate_issuance_params(
    *,
    tag: str,
    days: Optional[int],
    never_expire: bool,
    plat: str,
    min_version_code: int,
) -> Tuple[str, int, str, int]:
    clean_tag = (tag or "").strip()
    if not clean_tag:
        raise ValueError("Tag must not be empty")
    if len(clean_tag) > MAX_TAG_LEN:
        raise ValueError(f"Tag length must be <= {MAX_TAG_LEN}")

    if plat not in VALID_TOKEN_PLATFORMS:
        raise ValueError(
            f"Token plat '{plat}' is incompatible with released clients; "
            f"must be one of {', '.join(VALID_TOKEN_PLATFORMS)}"
        )

    if never_expire:
        eff_days = 0
    else:
        if days is None or isinstance(days, bool) or not isinstance(days, int):
            raise ValueError("days must be an integer between 1 and 3650 (or set never_expire=True)")
        if days < 1 or days > MAX_DAYS:
            raise ValueError(
                f"days must be between 1 and {MAX_DAYS} (blank/0/negative cannot silently become permanent; pass --never-expire explicitly)"
            )
        eff_days = days

    if isinstance(min_version_code, bool) or not isinstance(min_version_code, int):
        raise ValueError("min_version_code must be an integer")
    if min_version_code < 0 or min_version_code > MAX_MIN_VC:
        raise ValueError(f"min_version_code must be between 0 and {MAX_MIN_VC}")
    if min_version_code > 0 and plat != "android":
        raise ValueError(
            f"min_version_code={min_version_code} is not enforced by released Windows/iOS clients "
            f"and is only permitted for Android-only tokens (plat='android', got plat='{plat}')"
        )
    return clean_tag, eff_days, plat, min_version_code


def encode_passcode(
    seed: bytes,
    *,
    tag: str = "beta",
    days: Optional[int] = 30,
    never_expire: bool = False,
    platforms: str = "all",
    shared: bool = False,
    experimental_oauth: bool = False,
    min_version_code: int = 0,
    now_epoch: Optional[int] = None,
    nonce: Optional[str] = None,
) -> str:
    """Encodes a single Windows-0.7.3-compatible MMAILAB1 token (`plat` in all/android/ios/windows)."""
    targets = parse_target_platforms(platforms)
    if len(targets) != 1:
        raise ValueError(
            f"Multi-platform selection '{platforms}' cannot be combined into a single token "
            f"(Windows 0.7.3 rejects comma combinations); use issue_passcodes() to split into "
            f"per-platform targeted tokens: {targets}"
        )
    plat = targets[0]
    clean_tag, eff_days, plat, min_vc = validate_issuance_params(
        tag=tag,
        days=days,
        never_expire=never_expire,
        plat=plat,
        min_version_code=min_version_code,
    )
    iat = int(time.time()) if now_epoch is None else int(now_epoch)
    exp = 0 if eff_days == 0 else iat + eff_days * 86400
    payload_obj: dict = {
        "exp": exp,
        "iat": iat,
        "plat": plat,
        "tag": clean_tag,
        "v": 1,
    }
    if shared:
        payload_obj["shared"] = True
    if experimental_oauth:
        payload_obj["exp_oauth"] = True
    if min_vc > 0:
        payload_obj["min_vc"] = min_vc
    if nonce is not None:
        if nonce:
            payload_obj["n"] = nonce
    else:
        payload_obj["n"] = secrets.token_hex(4)

    payload_bytes = ed.canonicalize_json(payload_obj).encode("utf-8")
    sig = ed.sign(seed, SIGN_DOMAIN + payload_bytes)
    return f"{TOKEN_PREFIX}{_b64url_encode(payload_bytes)}.{_b64url_encode(sig)}"


def issue_passcodes(
    seed: bytes,
    *,
    tag: str = "channel-01",
    days: Optional[int] = 30,
    never_expire: bool = False,
    platforms: str = "all",
    shared: bool = False,
    experimental_oauth: bool = False,
    min_version_code: int = 0,
    count: int = 1,
    now_epoch: Optional[int] = None,
) -> List[Dict[str, object]]:
    """Mints validated, batch-deduplicated passcodes, splitting multi-platform requests cleanly."""
    if isinstance(count, bool) or not isinstance(count, int) or count < 1 or count > MAX_COUNT:
        raise ValueError(f"count must be an integer between 1 and {MAX_COUNT}")
    targets = parse_target_platforms(platforms)
    pub = ed.public_key_from_seed(seed)
    results: List[Dict[str, object]] = []
    seen_tokens: set[str] = set()
    for target in targets:
        for _ in range(count):
            for _attempt in range(8):
                code = encode_passcode(
                    seed,
                    tag=tag,
                    days=days,
                    never_expire=never_expire,
                    platforms=target,
                    shared=shared,
                    experimental_oauth=experimental_oauth,
                    min_version_code=min_version_code,
                    now_epoch=now_epoch,
                )
                if code not in seen_tokens:
                    seen_tokens.add(code)
                    break
            else:
                raise RuntimeError("Failed to generate unique token in batch")
            info = decode_and_verify_passcode(code, pub, now_epoch=now_epoch)
            assert info["valid_signature"], "Self-verify failed!"
            results.append({"platform": target, "token": code, "info": info})
    return results


def _evaluate_platform_activation(
    claims: dict,
    *,
    signature_valid: bool,
    target_platform: str,
    now_sec: int,
    app_version_code: int = 0,
) -> Dict[str, object]:
    """Evaluates activation using each platform's ACTUAL released client rules."""
    if not signature_valid:
        return {"ok": False, "reason": "Ed25519 signature invalid"}
    if not isinstance(claims, dict):
        return {"ok": False, "reason": "Payload JSON invalid"}
    if claims.get("v") != 1:
        return {"ok": False, "reason": f"Unsupported version v={claims.get('v')}"}

    raw_plat = str(claims.get("plat", "all") or "all").strip().lower()
    if target_platform in ("windows", "ios"):
        # Released Windows 0.7.3 (flutter/lib/core/ai_lab_passcode.dart):
        # accepts ONLY "" / "all" / exact single target platform (NO comma lists!).
        plat_ok = raw_plat in ("", "all", target_platform)
    else:
        # Android client supports single platform, "all", and legacy comma list parsing.
        parts = [_normalize_single_platform(x) for x in re.split(r"[,;/\s]+", raw_plat) if x.strip()]
        plat_ok = (not parts) or ("all" in parts) or (target_platform in parts)

    if not plat_ok:
        return {"ok": False, "reason": f"Platform '{raw_plat}' rejected by {target_platform} client"}

    min_vc = int(claims.get("min_vc", 0) or 0)
    if target_platform == "android" and min_vc > 0 and app_version_code > 0 and app_version_code < min_vc:
        return {"ok": False, "reason": f"App versionCode {app_version_code} < min_vc {min_vc}"}

    exp = int(claims.get("exp", 0) or 0)
    if exp > 0 and now_sec > exp:
        return {"ok": False, "reason": "Passcode expired"}

    note = ""
    if target_platform in ("windows", "ios") and min_vc > 0:
        note = "min_vc is ignored by released Windows/iOS verifier"
    out: Dict[str, object] = {"ok": True, "reason": "Activatable"}
    if note:
        out["warning"] = note
    return out


def decode_and_verify_passcode(
    code: str,
    pub: bytes,
    *,
    now_epoch: Optional[int] = None,
    target_platform: Optional[str] = None,
    app_version_code: int = 0,
) -> dict:
    canonical = extract_token(code)
    m = _TOKEN_EXTRACT_RE.fullmatch(canonical)
    if not m:
        raise ValueError("Invalid token format (expected MMAILAB1.<payload>.<sig>)")
    payload_bytes = _b64url_decode(m.group(1))
    sig = _b64url_decode(m.group(2))
    if len(sig) != 64:
        raise ValueError(f"Invalid signature length {len(sig)} (expected 64)")
    valid_sig = ed.verify(pub, SIGN_DOMAIN + payload_bytes, sig)
    claims = json.loads(payload_bytes.decode("utf-8"))
    now_sec = int(time.time()) if now_epoch is None else int(now_epoch)
    exp = int(claims.get("exp", 0) or 0) if isinstance(claims, dict) else 0
    expired = exp > 0 and now_sec > exp
    expire_date = (
        "永久有效"
        if exp <= 0
        else datetime.fromtimestamp(exp, tz=timezone.utc).strftime("%Y-%m-%d")
    )
    by_platform = {
        p: _evaluate_platform_activation(
            claims,
            signature_valid=valid_sig,
            target_platform=p,
            now_sec=now_sec,
            app_version_code=app_version_code if p == "android" else 0,
        )
        for p in SINGLE_PLATFORMS
    }
    res = {
        "valid_signature": valid_sig,
        "expired": expired,
        "expire_date": expire_date,
        "activatable_by_platform": by_platform,
        "claims": claims,
        "canonical_token": canonical,
    }
    if target_platform:
        tp = _normalize_single_platform(target_platform)
        if tp not in SINGLE_PLATFORMS:
            raise ValueError(f"Unknown target_platform '{target_platform}' (use android, ios, windows)")
        ev = _evaluate_platform_activation(
            claims,
            signature_valid=valid_sig,
            target_platform=tp,
            now_sec=now_sec,
            app_version_code=app_version_code,
        )
        res["target_platform"] = tp
        res["activatable_for_target"] = ev["ok"]
        res["target_reason"] = ev["reason"]
    return res


def _vault_keystream(enc_key: bytes, nonce: bytes, length: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < length:
        out.extend(hashlib.sha256(enc_key + nonce + struct.pack(">I", counter)).digest())
        counter += 1
    return bytes(out[:length])


def encrypt_mobile_vault(seed: bytes, pub: bytes, password: str) -> dict:
    """Encrypts 32-byte Ed25519 seed using PBKDF2-HMAC-SHA256 + SHA256-CTR + Encrypt-then-MAC."""
    if not password or len(password) < 6:
        raise ValueError("Master password must be at least 6 characters")
    if len(seed) != 32 or len(pub) != 32:
        raise ValueError("Ed25519 seed and public key must be 32 bytes each")
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(16)
    derived = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, VAULT_PBKDF2_ITERS, dklen=64
    )
    enc_key, mac_key = derived[:32], derived[32:]
    stream = _vault_keystream(enc_key, nonce, len(seed))
    ciphertext = bytes(a ^ b for a, b in zip(seed, stream))
    mac = hmac.new(
        mac_key, b"MARCO-ED25519-VAULT-V1:" + salt + nonce + ciphertext, hashlib.sha256
    ).digest()
    return {
        "format": "marco-ai-ed25519-vault-v1",
        "kdf": "pbkdf2-hmac-sha256",
        "iterations": VAULT_PBKDF2_ITERS,
        "salt_hex": salt.hex(),
        "nonce_hex": nonce.hex(),
        "ciphertext_hex": ciphertext.hex(),
        "mac_hex": mac.hex(),
        "pub_hex": pub.hex(),
    }


def decrypt_mobile_vault(vault: dict, password: str) -> Tuple[bytes, bytes]:
    if vault.get("format") != "marco-ai-ed25519-vault-v1":
        raise ValueError("Unsupported mobile vault format")
    salt = bytes.fromhex(vault["salt_hex"])
    nonce = bytes.fromhex(vault["nonce_hex"])
    ciphertext = bytes.fromhex(vault["ciphertext_hex"])
    expected_mac = bytes.fromhex(vault["mac_hex"])
    iters = int(vault.get("iterations", VAULT_PBKDF2_ITERS))
    derived = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iters, dklen=64)
    enc_key, mac_key = derived[:32], derived[32:]
    actual_mac = hmac.new(
        mac_key, b"MARCO-ED25519-VAULT-V1:" + salt + nonce + ciphertext, hashlib.sha256
    ).digest()
    if not hmac.compare_digest(actual_mac, expected_mac):
        raise ValueError("Wrong password or corrupted vault")
    stream = _vault_keystream(enc_key, nonce, len(ciphertext))
    seed = bytes(a ^ b for a, b in zip(ciphertext, stream))
    pub = bytes.fromhex(vault["pub_hex"])
    if ed.public_key_from_seed(seed) != pub:
        raise ValueError("Vault public key mismatch")
    return seed, pub


def cmd_issue(args: argparse.Namespace) -> int:
    key_path = Path(args.key_file)
    if not key_path.exists():
        print(f"ERROR: Ed25519 key not found at {key_path}", file=sys.stderr)
        return 1
    seed, pub = read_ed25519_seed(key_path)
    is_official = pub.hex().lower() == DEFAULT_PUBKEY_HEX.lower()
    if not is_official and not args.allow_test_key:
        print(
            f"ERROR: Key public hex {pub.hex()} does not match pinned official public key "
            f"{DEFAULT_PUBKEY_HEX}. Pass --allow-test-key explicitly for local test issuance.",
            file=sys.stderr,
        )
        return 1

    try:
        items = issue_passcodes(
            seed,
            tag=args.tag,
            days=None if args.never_expire else args.days,
            never_expire=args.never_expire,
            platforms=args.platforms,
            shared=args.shared,
            experimental_oauth=args.experimental_oauth,
            min_version_code=args.min_version_code,
            count=args.count,
        )
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    targets = parse_target_platforms(args.platforms)
    exp_label = "永久有效" if args.never_expire else f"{args.days} 天有效"
    mode_label = "OFFICIAL" if is_official else "TEST-KEY"
    print(
        f"# [{mode_label}] tag={args.tag} | targets={','.join(targets)} | shared={args.shared} | "
        f"exp_oauth={args.experimental_oauth} | min_vc={args.min_version_code} | {exp_label} | pub={pub.hex()[:12]}..."
    )
    if len(targets) > 1:
        print(
            f"# Note: split multi-platform request into {len(targets)} per-platform targeted tokens "
            f"for Windows 0.7.3 compatibility (never widened to 'all')."
        )
    for idx, item in enumerate(items):
        prefix = f"[{item['platform']}] " if len(targets) > 1 else ""
        if len(items) > 1:
            print(f"{idx + 1}. {prefix}{item['token']}")
        else:
            print(item["token"])
    return 0


def cmd_export_mobile_vault(args: argparse.Namespace) -> int:
    key_path = Path(args.key_file)
    if not key_path.exists():
        print(f"ERROR: Ed25519 key not found at {key_path}", file=sys.stderr)
        return 1
    seed, pub = read_ed25519_seed(key_path)
    password = args.password
    if not password:
        p1 = getpass.getpass("设置手机发码器主密码（至少 6 位）：")
        p2 = getpass.getpass("再次输入主密码确认：")
        if p1 != p2:
            print("ERROR: 两次输入的密码不一致", file=sys.stderr)
            return 1
        password = p1
    vault = encrypt_mobile_vault(seed, pub, password)
    dec_seed, dec_pub = decrypt_mobile_vault(vault, password)
    assert dec_seed == seed and dec_pub == pub

    vault_out = Path(args.vault_out)
    vault_out.parent.mkdir(parents=True, exist_ok=True)
    vault_out.write_text(json.dumps(vault, indent=2) + "\n", encoding="utf-8")
    print(f"Encrypted Ed25519 mobile vault written -> {vault_out}")

    if TEMPLATE_HTML_PATH.exists():
        template = TEMPLATE_HTML_PATH.read_text(encoding="utf-8")
        marker = "/*__PRELOADED_ENCRYPTED_VAULT__*/null"
        if marker in template:
            ready_html = template.replace(marker, json.dumps(vault, separators=(",", ":")), 1)
            html_out = Path(args.html_out)
            html_out.parent.mkdir(parents=True, exist_ok=True)
            html_out.write_text(ready_html, encoding="utf-8")
            print(f"Ready-to-transfer phone keygen HTML written -> {html_out}")
            print("传到你自己的手机（iPhone 文件/Safari 或安卓浏览器打开）输入主密码即可随时离线签发三端通用或单端 MMAILAB1 口令。")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    pub = bytes.fromhex(args.pub_hex.strip() if args.pub_hex else DEFAULT_PUBKEY_HEX)
    try:
        info = decode_and_verify_passcode(
            args.code,
            pub,
            target_platform=args.target_platform or None,
            app_version_code=args.app_version_code,
        )
    except Exception as e:
        print(json.dumps({"valid_signature": False, "error": str(e)}, ensure_ascii=False, indent=2))
        return 2
    print(json.dumps(info, ensure_ascii=False, indent=2))
    if not info["valid_signature"]:
        return 2
    if args.target_platform and not info.get("activatable_for_target", False):
        return 3
    return 0


def main() -> int:
    priv_dir = _default_private_dir()
    parser = argparse.ArgumentParser(
        description="Unified Android/iOS/Windows Ed25519 MMAILAB1 passcode generator"
    )
    parser.add_argument(
        "--key-file",
        default=str(_default_key_path()),
        help="Path to 32-byte Ed25519 private seed file (default: private/ai-lab-ed25519.key)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_issue = sub.add_parser("issue", help="Mint one or more signed MMAILAB1 passcodes")
    p_issue.add_argument("--tag", default="channel-01", help="Batch/channel label")
    p_issue.add_argument(
        "--days",
        type=int,
        default=30,
        help="Valid days from now (1..3650; use --never-expire for permanent codes)",
    )
    p_issue.add_argument("--never-expire", action="store_true", help="Explicitly issue non-expiring code")
    p_issue.add_argument("--shared", action="store_true", help="Mark as shared channel code")
    p_issue.add_argument(
        "--platforms",
        default="all",
        help="Target platform(s): all, android, ios, windows (multiple values split into per-platform targeted tokens)",
    )
    p_issue.add_argument(
        "--experimental-oauth",
        action="store_true",
        help="Allow experimental OpenAI OAuth option in clients",
    )
    p_issue.add_argument(
        "--min-version-code",
        type=int,
        default=0,
        help="Optional min versionCode (Android-only tokens; must be 0 for all/windows/ios)",
    )
    p_issue.add_argument("--count", type=int, default=1, help="Passcodes per target platform (1..50)")
    p_issue.add_argument(
        "--allow-test-key",
        action="store_true",
        help="Allow signing with a non-official test Ed25519 key",
    )
    p_issue.set_defaults(func=cmd_issue)

    p_exp = sub.add_parser(
        "export-mobile-vault",
        help="Export password-encrypted Ed25519 vault + ready phone HTML keygen into private/",
    )
    p_exp.add_argument("--password", default="", help="Master password (prompted if omitted)")
    p_exp.add_argument(
        "--vault-out",
        default=str(priv_dir / "ai_lab_mobile_vault.json"),
        help="Output encrypted vault JSON path",
    )
    p_exp.add_argument(
        "--html-out",
        default=str(priv_dir / "marco_phone_keygen_ready.html"),
        help="Output ready phone HTML path",
    )
    p_exp.set_defaults(func=cmd_export_mobile_vault)

    p_verify = sub.add_parser("verify", help="Verify and inspect any MMAILAB1 passcode offline")
    p_verify.add_argument("code", help="Passcode string (MMAILAB1....)")
    p_verify.add_argument("--pub-hex", default="", help="Optional 32-byte Ed25519 public key hex")
    p_verify.add_argument(
        "--target-platform",
        default="",
        help="Optional target platform to check activation eligibility (android, ios, windows)",
    )
    p_verify.add_argument(
        "--app-version-code",
        type=int,
        default=0,
        help="Optional Android app versionCode to check against min_vc",
    )
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
