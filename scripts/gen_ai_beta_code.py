#!/usr/bin/env python3
"""Unified cross-platform (Android Mobile / iOS / Windows) RFC 8032 Ed25519 passcode CLI
and password-encrypted mobile HTML keygen exporter for Marco Movie AI Lab.

Canonical token format (shared with scripts/sign_manifest.py & flutter/lib/core/ai_lab_passcode.dart):
  MMAILAB1.<payload_b64url>.<sig_b64url>
  Signing message: b"marco-ai-lab-v1:" + canonical_json_bytes

Zero external dependencies (pure Python 3 standard library).
Private key stays strictly local under private/ai-lab-ed25519.key (gitignored).

Usage examples:
  # 1. Issue a 3-platform (Android+iOS+Windows) shared 30-day Tencent Channel passcode
  python -X utf8 scripts/gen_ai_beta_code.py issue --tag channel-01 --days 30 --shared --platforms all

  # 2. Issue 5 iOS-only passcodes valid for 60 days
  python -X utf8 scripts/gen_ai_beta_code.py issue --tag ios-wave1 --days 60 --platforms ios --count 5

  # 3. Issue a permanent core-tester passcode with experimental OAuth enabled
  python -X utf8 scripts/gen_ai_beta_code.py issue --tag core-admin --never-expire --experimental-oauth

  # 4. Export password-encrypted vault & ready-to-transfer phone HTML keygen into private/
  python -X utf8 scripts/gen_ai_beta_code.py export-mobile-vault

  # 5. Verify any MMAILAB1 passcode offline
  python -X utf8 scripts/gen_ai_beta_code.py verify MMAILAB1....
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
from pathlib import Path
from typing import Optional, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))
import sign_manifest as ed

TOKEN_PREFIX = "MMAILAB1."
SIGN_DOMAIN = b"marco-ai-lab-v1:"
DEFAULT_PUBKEY_HEX = "1dbeaed851b873d7c327d30d718fca0ac1509ef5ac4061b9bd1aa90c841c6929"
VAULT_PBKDF2_ITERS = 100_000

TEMPLATE_HTML_PATH = SCRIPT_DIR / "ai_beta_phone_keygen.html"


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
    key = _default_key_path()
    return key.parent


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _b64url_decode(text: str) -> bytes:
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


def normalize_platforms(raw: str) -> str:
    text = (raw or "all").strip().lower()
    if text in ("", "all", "*"):
        return "all"
    seen = []
    for part in re.split(r"[,;/\s]+", text):
        p = part.strip()
        if not p:
            continue
        if p in ("android-mobile", "mobile"):
            p = "android"
        elif p in ("win", "pc"):
            p = "windows"
        elif p in ("iphone", "ipad"):
            p = "ios"
        if p not in ("android", "ios", "windows", "macos"):
            raise ValueError(f"Unknown platform '{p}' (use all, android, ios, windows)")
        if p not in seen:
            seen.append(p)
    if not seen or set(seen) >= {"android", "ios", "windows"}:
        return "all"
    return ",".join(seen)


def encode_passcode(
    seed: bytes,
    *,
    tag: str = "beta",
    days: int = 30,
    platforms: str = "all",
    shared: bool = False,
    experimental_oauth: bool = False,
    min_version_code: int = 0,
    now_epoch: Optional[int] = None,
    nonce: Optional[str] = None,
) -> str:
    iat = int(time.time()) if now_epoch is None else int(now_epoch)
    exp = 0 if days <= 0 else iat + int(days) * 86400
    plat = normalize_platforms(platforms)
    payload_obj: dict = {
        "exp": exp,
        "iat": iat,
        "plat": plat,
        "tag": (tag or "beta").strip() or "beta",
        "v": 1,
    }
    if shared:
        payload_obj["shared"] = True
    if experimental_oauth:
        payload_obj["exp_oauth"] = True
    if min_version_code > 0:
        payload_obj["min_vc"] = int(min_version_code)
    if nonce is not None:
        if nonce:
            payload_obj["n"] = nonce
    else:
        payload_obj["n"] = secrets.token_hex(3)

    payload_bytes = ed.canonicalize_json(payload_obj).encode("utf-8")
    sig = ed.sign(seed, SIGN_DOMAIN + payload_bytes)
    return f"{TOKEN_PREFIX}{_b64url_encode(payload_bytes)}.{_b64url_encode(sig)}"


def decode_and_verify_passcode(code: str, pub: bytes) -> dict:
    collapsed = "".join((code or "").split())
    m = re.search(r"MMAILAB1\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)", collapsed)
    if not m:
        raise ValueError("Invalid token format (expected MMAILAB1.<payload>.<sig>)")
    payload_bytes = _b64url_decode(m.group(1))
    sig = _b64url_decode(m.group(2))
    if len(sig) != 64:
        raise ValueError(f"Invalid signature length {len(sig)} (expected 64)")
    valid = ed.verify(pub, SIGN_DOMAIN + payload_bytes, sig)
    claims = json.loads(payload_bytes.decode("utf-8"))
    return {
        "valid_signature": valid,
        "claims": claims,
        "canonical_token": m.group(0),
    }


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
    days = 0 if args.never_expire else args.days
    plat = normalize_platforms(args.platforms)
    exp_label = "永久有效" if days <= 0 else f"{days} 天有效"
    print(
        f"# tag={args.tag} | plat={plat} | shared={args.shared} | exp_oauth={args.experimental_oauth} | {exp_label} | pub={pub.hex()[:12]}..."
    )
    for idx in range(args.count):
        code = encode_passcode(
            seed,
            tag=args.tag,
            days=days,
            platforms=plat,
            shared=args.shared,
            experimental_oauth=args.experimental_oauth,
            min_version_code=args.min_version_code,
        )
        info = decode_and_verify_passcode(code, pub)
        assert info["valid_signature"], "Self-verify failed!"
        print(f"{idx + 1}. {code}" if args.count > 1 else code)
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
            print("传到你自己的手机（iPhone 文件/Safari 或安卓浏览器打开）输入主密码即可随时离线签发三端通用 MMAILAB1 口令。")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    pub = bytes.fromhex(args.pub_hex.strip() if args.pub_hex else DEFAULT_PUBKEY_HEX)
    info = decode_and_verify_passcode(args.code, pub)
    print(json.dumps(info, ensure_ascii=False, indent=2))
    return 0 if info["valid_signature"] else 2


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
    p_issue.add_argument("--days", type=int, default=30, help="Valid days from now")
    p_issue.add_argument("--never-expire", action="store_true", help="Issue non-expiring code")
    p_issue.add_argument("--shared", action="store_true", help="Mark as shared channel code")
    p_issue.add_argument(
        "--platforms",
        default="all",
        help="Target platforms: all (default: Android+iOS+Windows) or comma list e.g. ios,android",
    )
    p_issue.add_argument(
        "--experimental-oauth",
        action="store_true",
        help="Allow experimental OpenAI OAuth option in clients",
    )
    p_issue.add_argument("--min-version-code", type=int, default=0, help="Optional min versionCode")
    p_issue.add_argument("--count", type=int, default=1, help="Number of passcodes to mint")
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
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
