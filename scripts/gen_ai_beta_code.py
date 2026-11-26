#!/usr/bin/env python3
"""Offline ECDSA P-256 passcode generator, verifier & mobile vault exporter for Marco Movie.

Unified across Android Mobile, iOS, and Windows (single P-256 public key embedded in all 3 apps).
Zero third-party dependencies (pure Python 3 standard library).

Private key is stored locally under android-mobile/private/ai_beta_signing.key (gitignored)
and MUST NEVER be committed or distributed.

Usage examples:
  # 1. Initialize author signing keypair (run once, back up safely!)
  python -X utf8 scripts/gen_ai_beta_code.py init-key

  # 2. Issue a 3-platform (Android+iOS+Windows) shared 30-day Tencent Channel passcode
  python -X utf8 scripts/gen_ai_beta_code.py issue --batch 1 --days 30 --shared --platforms all

  # 3. Issue 5 iOS-only tester passcodes valid for 60 days
  python -X utf8 scripts/gen_ai_beta_code.py issue --batch 2 --days 60 --platforms ios --count 5

  # 4. Issue a permanent core-tester passcode with experimental OAuth enabled
  python -X utf8 scripts/gen_ai_beta_code.py issue --batch 99 --never-expire --experimental-oauth

  # 5. Export password-encrypted vault & ready-to-transfer offline Mobile HTML Keygen
  python -X utf8 scripts/gen_ai_beta_code.py export-mobile-vault

  # 6. Verify any passcode offline
  python -X utf8 scripts/gen_ai_beta_code.py verify MM-AI1-...
"""

from __future__ import annotations

import argparse
import base64
import datetime
import getpass
import hashlib
import hmac
import json
import secrets
import struct
import sys
from pathlib import Path
from typing import Optional, Tuple

# NIST P-256 (secp256r1) domain parameters
_P = 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
_A = _P - 3
_B = 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B
_N = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_GX = 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296
_GY = 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5
_G = (_GX, _GY)

TOKEN_PREFIX = "MM-AI1-"
DOMAIN_SEP = b"MARCO-AI-BETA-V1:"
EPOCH_DATE = datetime.date(2026, 1, 1)

FLAG_CORE_AI = 0x01
FLAG_EXPERIMENTAL_OAUTH = 0x02
FLAG_SHARED_CHANNEL = 0x04
FLAG_PLATFORM_ANDROID = 0x10
FLAG_PLATFORM_IOS = 0x20
FLAG_PLATFORM_WINDOWS = 0x40
FLAG_PLATFORM_MASK = 0x70

VAULT_PBKDF2_ITERS = 100_000

ROOT_DIR = Path(__file__).resolve().parents[1]
DEFAULT_KEY_PATH = ROOT_DIR / "android-mobile" / "private" / "ai_beta_signing.key"
DEFAULT_VAULT_PATH = ROOT_DIR / "android-mobile" / "private" / "ai_beta_mobile_vault.json"
DEFAULT_READY_HTML_PATH = ROOT_DIR / "android-mobile" / "private" / "marco_phone_keygen_ready.html"
TEMPLATE_HTML_PATH = ROOT_DIR / "scripts" / "ai_beta_phone_keygen.html"


def _modinv(a: int, m: int) -> int:
    return pow(a % m, -1, m)


def _point_add(
    p1: Optional[Tuple[int, int]], p2: Optional[Tuple[int, int]]
) -> Optional[Tuple[int, int]]:
    if p1 is None:
        return p2
    if p2 is None:
        return p1
    x1, y1 = p1
    x2, y2 = p2
    if x1 == x2:
        if (y1 + y2) % _P == 0:
            return None
        lam = (3 * x1 * x1 + _A) * _modinv(2 * y1, _P) % _P
    else:
        lam = (y2 - y1) * _modinv(x2 - x1, _P) % _P
    x3 = (lam * lam - x1 - x2) % _P
    y3 = (lam * (x1 - x3) - y1) % _P
    return (x3, y3)


def _scalar_mul(k: int, point: Optional[Tuple[int, int]]) -> Optional[Tuple[int, int]]:
    if k % _N == 0 or point is None:
        return None
    result = None
    addend = point
    while k > 0:
        if k & 1:
            result = _point_add(result, addend)
        addend = _point_add(addend, addend)
        k >>= 1
    return result


def _is_on_curve(point: Optional[Tuple[int, int]]) -> bool:
    if point is None:
        return False
    x, y = point
    return 0 <= x < _P and 0 <= y < _P and (y * y - (x * x * x + _A * x + _B)) % _P == 0


def _rfc6979_k(priv_int: int, digest_bytes: bytes) -> int:
    """RFC 6979 deterministic nonce generation for P-256 + SHA-256."""
    x_bytes = priv_int.to_bytes(32, "big")
    h1 = int.from_bytes(digest_bytes, "big") % _N
    h1_bytes = h1.to_bytes(32, "big")
    v = b"\x01" * 32
    k = b"\x00" * 32
    k = hmac.new(k, v + b"\x00" + x_bytes + h1_bytes, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    k = hmac.new(k, v + b"\x01" + x_bytes + h1_bytes, hashlib.sha256).digest()
    v = hmac.new(k, v, hashlib.sha256).digest()
    while True:
        v = hmac.new(k, v, hashlib.sha256).digest()
        cand = int.from_bytes(v, "big")
        if 1 <= cand < _N:
            return cand
        k = hmac.new(k, v + b"\x00", hashlib.sha256).digest()
        v = hmac.new(k, v, hashlib.sha256).digest()


def generate_keypair() -> Tuple[int, bytes]:
    d = secrets.randbelow(_N - 1) + 1
    pub = _scalar_mul(d, _G)
    assert pub is not None and _is_on_curve(pub)
    pub_uncompressed = b"\x04" + pub[0].to_bytes(32, "big") + pub[1].to_bytes(32, "big")
    return d, pub_uncompressed


def ecdsa_sign(priv_int: int, message: bytes) -> Tuple[int, int]:
    digest = hashlib.sha256(message).digest()
    z = int.from_bytes(digest, "big")
    k = _rfc6979_k(priv_int, digest)
    pt = _scalar_mul(k, _G)
    assert pt is not None
    r = pt[0] % _N
    if r == 0:
        raise ValueError("Invalid ECDSA r=0")
    s = (_modinv(k, _N) * (z + r * priv_int)) % _N
    if s == 0:
        raise ValueError("Invalid ECDSA s=0")
    if s > _N // 2:
        s = _N - s
    return r, s


def ecdsa_verify(pub_uncompressed: bytes, message: bytes, r: int, s: int) -> bool:
    if len(pub_uncompressed) != 65 or pub_uncompressed[0] != 0x04:
        return False
    qx = int.from_bytes(pub_uncompressed[1:33], "big")
    qy = int.from_bytes(pub_uncompressed[33:65], "big")
    q = (qx, qy)
    if not _is_on_curve(q):
        return False
    if not (1 <= r < _N and 1 <= s < _N):
        return False
    digest = hashlib.sha256(message).digest()
    z = int.from_bytes(digest, "big")
    w = _modinv(s, _N)
    u1 = (z * w) % _N
    u2 = (r * w) % _N
    pt = _point_add(_scalar_mul(u1, _G), _scalar_mul(u2, q))
    return pt is not None and (pt[0] % _N) == r


def parse_platforms_arg(raw: str) -> int:
    text = (raw or "all").strip().lower()
    if text in ("", "all", "*"):
        return 0  # 0 = all 3 platforms allowed (backwards-compatible default)
    mask = 0
    for part in text.split(","):
        p = part.strip()
        if p in ("android", "android-mobile", "mobile"):
            mask |= FLAG_PLATFORM_ANDROID
        elif p in ("ios", "iphone", "ipad"):
            mask |= FLAG_PLATFORM_IOS
        elif p in ("win", "windows", "pc"):
            mask |= FLAG_PLATFORM_WINDOWS
        elif p:
            raise ValueError(f"Unknown platform '{p}' (use all, android, ios, windows)")
    return 0 if mask == FLAG_PLATFORM_MASK else mask


def platform_scope_label(flags: int) -> str:
    mask = flags & FLAG_PLATFORM_MASK
    if mask == 0 or mask == FLAG_PLATFORM_MASK:
        return "三端通用 (Android/iOS/Windows)"
    names = []
    if mask & FLAG_PLATFORM_ANDROID:
        names.append("Android")
    if mask & FLAG_PLATFORM_IOS:
        names.append("iOS")
    if mask & FLAG_PLATFORM_WINDOWS:
        names.append("Windows")
    return "仅限 " + "/".join(names)


def encode_passcode(
    priv_int: int,
    *,
    batch_id: int,
    expire_day: int,
    flags: int,
    min_version_code: int = 0,
    nonce: Optional[int] = None,
) -> str:
    if not (0 <= batch_id <= 0xFFFF):
        raise ValueError("batch_id must be 0..65535")
    if not (0 <= expire_day <= 0xFFFF):
        raise ValueError("expire_day must be 0..65535")
    if not (0 <= min_version_code <= 0xFFFF):
        raise ValueError("min_version_code must be 0..65535")
    actual_nonce = secrets.randbelow(0x10000) if nonce is None else (nonce & 0xFFFF)
    payload = struct.pack(
        ">BBHHHH",
        1,
        flags & 0xFF,
        batch_id,
        expire_day,
        min_version_code,
        actual_nonce,
    )
    r, s = ecdsa_sign(priv_int, DOMAIN_SEP + payload)
    raw = payload + r.to_bytes(32, "big") + s.to_bytes(32, "big")
    b64 = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return TOKEN_PREFIX + b64


def decode_and_verify_passcode(code: str, pub_uncompressed: bytes) -> dict:
    cleaned = "".join(code.split())
    if not cleaned.startswith(TOKEN_PREFIX):
        raise ValueError("Invalid token prefix (expected MM-AI1-)")
    b64 = cleaned[len(TOKEN_PREFIX) :]
    pad = "=" * ((4 - len(b64) % 4) % 4)
    raw = base64.urlsafe_b64decode(b64 + pad)
    if len(raw) != 74:
        raise ValueError(f"Invalid decoded length {len(raw)} (expected 74)")
    payload = raw[:10]
    r = int.from_bytes(raw[10:42], "big")
    s = int.from_bytes(raw[42:74], "big")
    valid = ecdsa_verify(pub_uncompressed, DOMAIN_SEP + payload, r, s)
    version, flags, batch_id, expire_day, min_vc, nonce = struct.unpack(">BBHHHH", payload)
    expire_date = (
        None if expire_day == 0 else (EPOCH_DATE + datetime.timedelta(days=expire_day)).isoformat()
    )
    mask = flags & FLAG_PLATFORM_MASK
    return {
        "valid_signature": valid,
        "version": version,
        "flags": flags,
        "core_ai": bool(flags & FLAG_CORE_AI),
        "experimental_oauth": bool(flags & FLAG_EXPERIMENTAL_OAUTH),
        "shared_channel": bool(flags & FLAG_SHARED_CHANNEL),
        "platforms": {
            "android": mask == 0 or bool(mask & FLAG_PLATFORM_ANDROID),
            "ios": mask == 0 or bool(mask & FLAG_PLATFORM_IOS),
            "windows": mask == 0 or bool(mask & FLAG_PLATFORM_WINDOWS),
            "label": platform_scope_label(flags),
        },
        "batch_id": batch_id,
        "expire_day": expire_day,
        "expire_date": expire_date or "never",
        "min_version_code": min_vc,
        "nonce": nonce,
    }


def _vault_keystream(enc_key: bytes, nonce: bytes, length: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < length:
        block = hashlib.sha256(enc_key + nonce + struct.pack(">I", counter)).digest()
        out.extend(block)
        counter += 1
    return bytes(out[:length])


def encrypt_mobile_vault(priv_int: int, pub_bytes: bytes, password: str) -> dict:
    """Encrypts P-256 private scalar with PBKDF2-HMAC-SHA256 + SHA256-CTR + Encrypt-then-MAC."""
    if not password or len(password) < 6:
        raise ValueError("Master password must be at least 6 characters")
    salt = secrets.token_bytes(16)
    nonce = secrets.token_bytes(16)
    derived = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, VAULT_PBKDF2_ITERS, dklen=64
    )
    enc_key, mac_key = derived[:32], derived[32:]
    plaintext = priv_int.to_bytes(32, "big")
    stream = _vault_keystream(enc_key, nonce, len(plaintext))
    ciphertext = bytes(a ^ b for a, b in zip(plaintext, stream))
    mac = hmac.new(mac_key, b"MARCO-VAULT-V1:" + salt + nonce + ciphertext, hashlib.sha256).digest()
    return {
        "format": "marco-ai-vault-v1",
        "kdf": "pbkdf2-hmac-sha256",
        "iterations": VAULT_PBKDF2_ITERS,
        "salt_hex": salt.hex(),
        "nonce_hex": nonce.hex(),
        "ciphertext_hex": ciphertext.hex(),
        "mac_hex": mac.hex(),
        "pub_uncompressed_hex": pub_bytes.hex(),
    }


def decrypt_mobile_vault(vault: dict, password: str) -> Tuple[int, bytes]:
    if vault.get("format") != "marco-ai-vault-v1":
        raise ValueError("Unsupported mobile vault format")
    salt = bytes.fromhex(vault["salt_hex"])
    nonce = bytes.fromhex(vault["nonce_hex"])
    ciphertext = bytes.fromhex(vault["ciphertext_hex"])
    expected_mac = bytes.fromhex(vault["mac_hex"])
    iters = int(vault.get("iterations", VAULT_PBKDF2_ITERS))
    derived = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iters, dklen=64)
    enc_key, mac_key = derived[:32], derived[32:]
    actual_mac = hmac.new(
        mac_key, b"MARCO-VAULT-V1:" + salt + nonce + ciphertext, hashlib.sha256
    ).digest()
    if not hmac.compare_digest(actual_mac, expected_mac):
        raise ValueError("Wrong password or corrupted vault")
    stream = _vault_keystream(enc_key, nonce, len(ciphertext))
    plaintext = bytes(a ^ b for a, b in zip(ciphertext, stream))
    priv_int = int.from_bytes(plaintext, "big")
    pub_bytes = bytes.fromhex(vault["pub_uncompressed_hex"])
    pt = _scalar_mul(priv_int, _G)
    assert pt is not None
    derived_pub = b"\x04" + pt[0].to_bytes(32, "big") + pt[1].to_bytes(32, "big")
    if derived_pub != pub_bytes:
        raise ValueError("Vault public key mismatch")
    return priv_int, pub_bytes


def _load_key_file(path: Path) -> Tuple[int, bytes]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("format") != "marco-ai-beta-p256-v1":
        raise ValueError("Unsupported key file format")
    priv_int = int(data["d_hex"], 16)
    pub_bytes = bytes.fromhex(data["pub_uncompressed_hex"])
    pt = _scalar_mul(priv_int, _G)
    assert pt is not None
    expected_pub = b"\x04" + pt[0].to_bytes(32, "big") + pt[1].to_bytes(32, "big")
    if pub_bytes != expected_pub:
        raise ValueError("Key file corrupted: public key mismatch")
    return priv_int, pub_bytes


def cmd_init_key(args: argparse.Namespace) -> int:
    key_path = Path(args.key_file)
    if key_path.exists() and not args.force:
        _, pub_bytes = _load_key_file(key_path)
        print(f"Key file already exists: {key_path}")
        print(f"PUBLIC_KEY_HEX={pub_bytes.hex()}")
        return 0
    key_path.parent.mkdir(parents=True, exist_ok=True)
    d, pub_bytes = generate_keypair()
    payload = {
        "format": "marco-ai-beta-p256-v1",
        "curve": "secp256r1",
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "d_hex": f"{d:064x}",
        "pub_uncompressed_hex": pub_bytes.hex(),
    }
    key_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Generated new P-256 signing keypair -> {key_path}")
    print(f"PUBLIC_KEY_HEX={pub_bytes.hex()}")
    return 0


def cmd_issue(args: argparse.Namespace) -> int:
    key_path = Path(args.key_file)
    if not key_path.exists():
        print(f"ERROR: signing key not found at {key_path}. Run `init-key` first.", file=sys.stderr)
        return 1
    priv_int, pub_bytes = _load_key_file(key_path)
    platform_mask = parse_platforms_arg(args.platforms)
    flags = FLAG_CORE_AI | platform_mask
    if args.experimental_oauth:
        flags |= FLAG_EXPERIMENTAL_OAUTH
    if args.shared:
        flags |= FLAG_SHARED_CHANNEL

    if args.never_expire:
        expire_day = 0
        expire_label = "永久有效"
    else:
        today = datetime.datetime.now(datetime.timezone.utc).date()
        target_date = today + datetime.timedelta(days=args.days)
        expire_day = max(1, (target_date - EPOCH_DATE).days)
        expire_label = target_date.isoformat()

    mode_label = "频道通用内测口令" if args.shared else "专属内测口令"
    oauth_label = "含实验性 OAuth" if args.experimental_oauth else "标准内测权限"
    plat_label = platform_scope_label(flags)
    print(
        f"# Batch #{args.batch:04d} | {plat_label} | {mode_label} | {oauth_label} | 有效期至: {expire_label} | 最低版本码: {args.min_version_code}"
    )
    for idx in range(args.count):
        code = encode_passcode(
            priv_int,
            batch_id=args.batch,
            expire_day=expire_day,
            flags=flags,
            min_version_code=args.min_version_code,
        )
        info = decode_and_verify_passcode(code, pub_bytes)
        assert info["valid_signature"], "Self-verify failed!"
        if args.count > 1:
            print(f"{idx + 1}. {code}")
        else:
            print(code)
    return 0


def cmd_export_mobile_vault(args: argparse.Namespace) -> int:
    key_path = Path(args.key_file)
    if not key_path.exists():
        print(f"ERROR: signing key not found at {key_path}. Run `init-key` first.", file=sys.stderr)
        return 1
    priv_int, pub_bytes = _load_key_file(key_path)
    password = args.password
    if not password:
        p1 = getpass.getpass("设置手机发码器主密码（至少 6 位）：")
        p2 = getpass.getpass("再次输入主密码确认：")
        if p1 != p2:
            print("ERROR: 两次输入的密码不一致", file=sys.stderr)
            return 1
        password = p1
    vault = encrypt_mobile_vault(priv_int, pub_bytes, password)
    # Round-trip decrypt check before writing
    dec_priv, dec_pub = decrypt_mobile_vault(vault, password)
    assert dec_priv == priv_int and dec_pub == pub_bytes

    vault_out = Path(args.vault_out)
    vault_out.parent.mkdir(parents=True, exist_ok=True)
    vault_json = json.dumps(vault, indent=2)
    vault_out.write_text(vault_json + "\n", encoding="utf-8")
    print(f"Encrypted mobile vault written -> {vault_out}")

    if TEMPLATE_HTML_PATH.exists():
        template = TEMPLATE_HTML_PATH.read_text(encoding="utf-8")
        marker = "/*__PRELOADED_ENCRYPTED_VAULT__*/null"
        if marker in template:
            ready_html = template.replace(marker, json.dumps(vault, separators=(",", ":")), 1)
            html_out = Path(args.html_out)
            html_out.parent.mkdir(parents=True, exist_ok=True)
            html_out.write_text(ready_html, encoding="utf-8")
            print(f"Ready-to-transfer phone keygen HTML written -> {html_out}")
            print("将此 HTML 发送到你自己的手机（iPhone 文件/Safari 或安卓浏览器打开）后输入主密码即可随时离线签发三端口令。")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    if args.pub_hex:
        pub_bytes = bytes.fromhex(args.pub_hex.strip())
    else:
        _, pub_bytes = _load_key_file(Path(args.key_file))
    info = decode_and_verify_passcode(args.code, pub_bytes)
    print(json.dumps(info, ensure_ascii=False, indent=2))
    return 0 if info["valid_signature"] else 2


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Unified Android/iOS/Windows ECDSA P-256 passcode generator for Marco Movie"
    )
    parser.add_argument(
        "--key-file",
        default=str(DEFAULT_KEY_PATH),
        help="Path to local author signing key JSON (default: android-mobile/private/ai_beta_signing.key)",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_init = sub.add_parser("init-key", help="Generate a new local ECDSA P-256 signing keypair")
    p_init.add_argument("--force", action="store_true", help="Overwrite existing key file")
    p_init.set_defaults(func=cmd_init_key)

    p_issue = sub.add_parser("issue", help="Mint one or more signed offline beta passcodes")
    p_issue.add_argument("--batch", type=int, default=1, help="Batch ID (1..65535)")
    p_issue.add_argument("--days", type=int, default=30, help="Valid days from today (UTC)")
    p_issue.add_argument("--never-expire", action="store_true", help="Issue non-expiring code")
    p_issue.add_argument("--shared", action="store_true", help="Mark as shared community/channel code")
    p_issue.add_argument(
        "--platforms",
        default="all",
        help="Target platforms: all (default: Android+iOS+Windows) or comma list of android,ios,windows",
    )
    p_issue.add_argument(
        "--experimental-oauth",
        action="store_true",
        help="Allow experimental OpenAI OAuth toggle in addition to standard API + OpenRouter/Kimi OAuth",
    )
    p_issue.add_argument(
        "--min-version-code",
        type=int,
        default=0,
        help="Minimum app versionCode (default: 0 for cross-platform compatibility)",
    )
    p_issue.add_argument("--count", type=int, default=1, help="Number of passcodes to mint")
    p_issue.set_defaults(func=cmd_issue)

    p_exp = sub.add_parser(
        "export-mobile-vault",
        help="Export password-encrypted vault JSON + ready-to-transfer phone HTML keygen into private/",
    )
    p_exp.add_argument("--password", default="", help="Master password (prompted interactively if omitted)")
    p_exp.add_argument("--vault-out", default=str(DEFAULT_VAULT_PATH), help="Output encrypted vault JSON path")
    p_exp.add_argument("--html-out", default=str(DEFAULT_READY_HTML_PATH), help="Output ready phone HTML path")
    p_exp.set_defaults(func=cmd_export_mobile_vault)

    p_verify = sub.add_parser("verify", help="Verify and inspect a beta passcode offline")
    p_verify.add_argument("code", help="Passcode string (MM-AI1-...)")
    p_verify.add_argument("--pub-hex", default="", help="Optional 65-byte uncompressed public key hex")
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
