#!/usr/bin/env python3
"""Offline ECDSA P-256 passcode generator & verifier for Marco Movie AI Beta Lab.

Zero third-party dependencies (pure Python 3 standard library).
Private key is stored locally under android-mobile/private/ai_beta_signing.key
(gitignored) and MUST NEVER be committed or distributed. Only the 65-byte
uncompressed public key hex is embedded in AiBetaGate.java.

Usage examples:
  # 1. Initialize author signing keypair (run once, back up the private key safely!)
  python -X utf8 scripts/gen_ai_beta_code.py init-key

  # 2. Issue a shared 30-day Tencent Channel beta passcode (batch #1)
  python -X utf8 scripts/gen_ai_beta_code.py issue --batch 1 --days 30 --shared

  # 3. Issue 5 individual tester codes with experimental OAuth enabled
  python -X utf8 scripts/gen_ai_beta_code.py issue --batch 2 --days 60 --experimental-oauth --count 5

  # 4. Issue a permanent core-tester code requiring app versionCode >= 103
  python -X utf8 scripts/gen_ai_beta_code.py issue --batch 99 --never-expire --experimental-oauth --min-version-code 103

  # 5. Verify any passcode offline
  python -X utf8 scripts/gen_ai_beta_code.py verify MM-AI1-...
"""

from __future__ import annotations

import argparse
import base64
import datetime
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

DEFAULT_KEY_PATH = (
    Path(__file__).resolve().parents[1]
    / "android-mobile"
    / "private"
    / "ai_beta_signing.key"
)


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
    # Canonical low-S normalization
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
    expire_date = None if expire_day == 0 else (EPOCH_DATE + datetime.timedelta(days=expire_day)).isoformat()
    return {
        "valid_signature": valid,
        "version": version,
        "flags": flags,
        "core_ai": bool(flags & FLAG_CORE_AI),
        "experimental_oauth": bool(flags & FLAG_EXPERIMENTAL_OAUTH),
        "shared_channel": bool(flags & FLAG_SHARED_CHANNEL),
        "batch_id": batch_id,
        "expire_day": expire_day,
        "expire_date": expire_date or "never",
        "min_version_code": min_vc,
        "nonce": nonce,
    }


def _load_key_file(path: Path) -> Tuple[int, bytes]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("format") != "marco-ai-beta-p256-v1":
        raise ValueError("Unsupported key file format")
    priv_int = int(data["d_hex"], 16)
    pub_bytes = bytes.fromhex(data["pub_uncompressed_hex"])
    # Sanity verify public key matches private scalar
    pt = _scalar_mul(priv_int, _G)
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
    flags = FLAG_CORE_AI
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
    print(
        f"# Batch #{args.batch:04d} | {mode_label} | {oauth_label} | 有效期至: {expire_label} | 最低版本码: {args.min_version_code}"
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
        description="Offline ECDSA P-256 passcode generator for Marco Movie AI Beta Lab"
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
        "--experimental-oauth",
        action="store_true",
        help="Allow experimental OpenAI OAuth toggle in addition to standard API + OpenRouter/Kimi OAuth",
    )
    p_issue.add_argument(
        "--min-version-code", type=int, default=103, help="Minimum Android versionCode (default: 103)"
    )
    p_issue.add_argument("--count", type=int, default=1, help="Number of passcodes to mint")
    p_issue.set_defaults(func=cmd_issue)

    p_verify = sub.add_parser("verify", help="Verify and inspect a beta passcode offline")
    p_verify.add_argument("code", help="Passcode string (MM-AI1-...)")
    p_verify.add_argument("--pub-hex", default="", help="Optional 65-byte uncompressed public key hex")
    p_verify.set_defaults(func=cmd_verify)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
