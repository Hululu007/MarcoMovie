#!/usr/bin/env python3
"""Pure Python RFC 8032 Ed25519 key generation, signer, and update manifest tool.

Zero external dependencies - uses only Python standard library (hashlib, json, sys, os).
"""

from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import sys
import tempfile

KEY_FILE_ENV = "MARCOMOVIE_SIGN_KEY_FILE"
PUBKEY_FILE_ENV = "MARCOMOVIE_SIGN_PUBKEY_FILE"
PUBKEY_HEX_ENV = "MARCOMOVIE_SIGN_PUBKEY"

# RFC 8032 Ed25519 Constants
Q = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493


def expmod(b: int, e: int, m: int) -> int:
    return pow(b, e, m)


def inv(x: int) -> int:
    return expmod(x, Q - 2, Q)


D = (-121665 * inv(121666)) % Q
I = expmod(2, (Q - 1) // 4, Q)


def recover_x(y: int) -> int:
    xx = ((y * y - 1) * inv(D * y * y + 1)) % Q
    x = expmod(xx, (Q + 3) // 8, Q)
    if (x * x - xx) % Q != 0:
        x = (x * I) % Q
    if x % 2 != 0:
        x = Q - x
    return x


By = (4 * inv(5)) % Q
Bx = recover_x(By)
B = (Bx, By)


def edwards(p: tuple[int, int], q: tuple[int, int]) -> tuple[int, int]:
    x1, y1 = p
    x2, y2 = q
    x3 = ((x1 * y2 + x2 * y1) * inv(1 + D * x1 * x2 * y1 * y2)) % Q
    y3 = ((y1 * y2 + x1 * x2) * inv(1 - D * x1 * x2 * y1 * y2)) % Q
    return (x3 % Q, y3 % Q)


def scalar_mult(p: tuple[int, int], e: int) -> tuple[int, int]:
    if e == 0:
        return (0, 1)
    q = scalar_mult(p, e // 2)
    q = edwards(q, q)
    if e % 2 != 0:
        q = edwards(q, p)
    return q


def encode_point(p: tuple[int, int]) -> bytes:
    x, y = p
    bits = [(y >> i) & 1 for i in range(255)] + [x & 1]
    res = bytearray(32)
    for i in range(256):
        res[i // 8] |= bits[i] << (i % 8)
    return bytes(res)


def decode_point(s: bytes) -> tuple[int, int] | None:
    if len(s) != 32:
        return None
    y = int.from_bytes(s, "little")
    sign = (y >> 255) & 1
    y &= (1 << 255) - 1
    x = recover_x(y)
    if (x & 1) != sign:
        x = Q - x
    return (x, y)


def public_key_from_seed(seed: bytes) -> bytes:
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    A = scalar_mult(B, a)
    return encode_point(A)


def sign(seed: bytes, message: bytes) -> bytes:
    h = hashlib.sha512(seed).digest()
    a = int.from_bytes(h[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    A = encode_point(scalar_mult(B, a))

    r_hash = hashlib.sha512(h[32:] + message).digest()
    r = int.from_bytes(r_hash, "little") % L
    R = encode_point(scalar_mult(B, r))

    k_hash = hashlib.sha512(R + A + message).digest()
    k = int.from_bytes(k_hash, "little") % L
    S = (r + k * a) % L
    return R + S.to_bytes(32, "little")


def verify(public_key: bytes, message: bytes, signature: bytes) -> bool:
    if len(signature) != 64 or len(public_key) != 32:
        return False
    r_bytes = signature[:32]
    s_bytes = signature[32:]
    s = int.from_bytes(s_bytes, "little")
    if s >= L:
        return False
    R = decode_point(r_bytes)
    A = decode_point(public_key)
    if R is None or A is None:
        return False
    k_hash = hashlib.sha512(r_bytes + public_key + message).digest()
    k = int.from_bytes(k_hash, "little") % L
    v1 = scalar_mult(B, s)
    v2 = edwards(R, scalar_mult(A, k % L))
    return v1 == v2


def canonicalize_json(obj) -> str:
    """Canonical compact JSON: sorted keys, no whitespace around separators."""
    if isinstance(obj, dict):
        sorted_pairs = []
        for k in sorted(obj.keys()):
            sorted_pairs.append(
                json.dumps(str(k), ensure_ascii=False)
                + ":"
                + canonicalize_json(obj[k])
            )
        return "{" + ",".join(sorted_pairs) + "}"
    elif isinstance(obj, list):
        return "[" + ",".join(canonicalize_json(x) for x in obj) + "]"
    elif isinstance(obj, str):
        return json.dumps(obj, ensure_ascii=False)
    elif isinstance(obj, bool):
        return "true" if obj else "false"
    elif obj is None:
        return "null"
    elif isinstance(obj, (int, float)):
        return str(obj)
    else:
        return json.dumps(obj, ensure_ascii=False)


def _read_32byte_key_file(path: Path, label: str) -> bytes:
    if not path.is_file():
        raise FileNotFoundError(f"{label} file not found: {path}")
    raw = path.read_bytes()
    if len(raw) == 32:
        return raw
    text_lines = [
        line.strip()
        for line in raw.decode("utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    hex_str = "".join(text_lines)
    seed = bytes.fromhex(hex_str)
    if len(seed) != 32:
        raise ValueError(f"{label} must be 32 bytes (64 hex chars), got {len(seed)} bytes")
    return seed


def extract_manifest_payload(data: dict) -> dict:
    if "payload" in data:
        payload = data["payload"]
        if not isinstance(payload, dict):
            raise ValueError("Manifest 'payload' field must be a JSON object")
        extra_keys = set(data.keys()) - {"payload", "signature", "sig"}
        if extra_keys:
            raise ValueError(
                f"Manifest with 'payload' must not contain unsigned outer fields: {sorted(extra_keys)}"
            )
        return payload
    return {k: v for k, v in data.items() if k not in ("signature", "sig")}


def resolve_private_key_file(cli_key_file: str | None) -> Path:
    candidate = cli_key_file or os.environ.get(KEY_FILE_ENV, "").strip()
    if not candidate:
        raise ValueError(
            f"Missing private key file: pass --key-file <path> or set {KEY_FILE_ENV}"
        )
    return Path(candidate)


def resolve_public_key_bytes(cli_pub_key: str | None, cli_pub_key_file: str | None) -> bytes:
    file_candidate = cli_pub_key_file or os.environ.get(PUBKEY_FILE_ENV, "").strip()
    if file_candidate:
        return _read_32byte_key_file(Path(file_candidate), "Public key")
    hex_candidate = (cli_pub_key or os.environ.get(PUBKEY_HEX_ENV, "")).strip()
    if not hex_candidate:
        raise ValueError(
            f"Missing public key: pass --pub-key <hex>, --pub-key-file <path>, "
            f"or set {PUBKEY_HEX_ENV} / {PUBKEY_FILE_ENV}"
        )
    pub = bytes.fromhex(hex_candidate)
    if len(pub) != 32:
        raise ValueError(f"Public key must be 32 bytes (64 hex chars), got {len(pub)} bytes")
    return pub


def sign_manifest_file(manifest_path: Path, key_file: Path) -> str:
    seed = _read_32byte_key_file(key_file, "Private key")
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("Manifest root must be a JSON object")
    payload = extract_manifest_payload(data)
    canonical = canonicalize_json(payload)
    sig = sign(seed, canonical.encode("utf-8"))
    sig_b64 = base64.b64encode(sig).decode("ascii")
    data["signature"] = sig_b64
    manifest_path.write_text(
        json.dumps(data, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return sig_b64


def verify_manifest_file(manifest_path: Path, pub: bytes) -> bool:
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        return False
    sig_b64 = data.get("signature") or data.get("sig")
    if not isinstance(sig_b64, str) or not sig_b64.strip():
        return False
    try:
        payload = extract_manifest_payload(data)
        sig = base64.b64decode(sig_b64, validate=True)
    except (ValueError, TypeError):
        return False
    canonical = canonicalize_json(payload)
    return verify(pub, canonical.encode("utf-8"), sig)


def self_test() -> None:
    seed = os.urandom(32)
    pub = public_key_from_seed(seed)
    for msg in (b"", b"r", b'{"platform":"windows","versionName":"0.5.30"}'):
        sig = sign(seed, msg)
        assert verify(pub, msg, sig), "Valid signature failed verification"
        assert not verify(
            pub, msg, bytes(sig[:-1]) + bytes([sig[-1] ^ 1])
        ), "Tampered signature unexpectedly passed"
        assert not verify(pub, msg + b"!", sig), "Tampered message unexpectedly passed"

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = Path(tmp)
        key_file = tmp_dir / "offline-ed25519.key"
        key_file.write_text(seed.hex() + "\n", encoding="utf-8")
        manifest_file = tmp_dir / "windows.json"
        manifest_file.write_text(
            json.dumps(
                {
                    "payload": {
                        "platform": "windows",
                        "versionName": "0.5.30",
                    }
                }
            ),
            encoding="utf-8",
        )
        sign_manifest_file(manifest_file, key_file)
        assert verify_manifest_file(manifest_file, pub), "Signed manifest failed verification"
        tampered = json.loads(manifest_file.read_text(encoding="utf-8"))
        tampered["windows"] = {"url": "https://tampered.example/setup.exe"}
        manifest_file.write_text(json.dumps(tampered), encoding="utf-8")
        assert not verify_manifest_file(
            manifest_file, pub
        ), "Outer wrapper tampering unexpectedly passed"

    print("ALL ED25519 MANIFEST SELF-TESTS PASSED!")


def main():
    parser = argparse.ArgumentParser(
        description=(
            "RFC 8032 Ed25519 Manifest Signer & Verifier. "
            "Generate keys offline and NEVER commit private keys to the repository."
        )
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("self-test", help="Run ephemeral Ed25519 self test")

    gen_cmd = sub.add_parser(
        "generate-key",
        help="Generate an offline Ed25519 keypair and write private key to a file",
    )
    gen_cmd.add_argument(
        "--out-key-file",
        required=True,
        help="Destination path for the offline 32-byte private seed file (must stay outside repo)",
    )
    gen_cmd.add_argument(
        "--out-pub-file",
        help="Optional destination path for the public key hex file",
    )

    sign_cmd = sub.add_parser("sign", help="Sign update manifest JSON using a private key file")
    sign_cmd.add_argument("manifest", help="Path to manifest JSON file")
    sign_cmd.add_argument(
        "-k",
        "--key-file",
        help=f"Path to private key seed file (or set {KEY_FILE_ENV})",
    )

    verify_cmd = sub.add_parser("verify", help="Verify update manifest JSON")
    verify_cmd.add_argument("manifest", help="Path to manifest JSON file")
    verify_cmd.add_argument(
        "--pub-key",
        help=f"Public key hex (64 hex chars, or set {PUBKEY_HEX_ENV})",
    )
    verify_cmd.add_argument(
        "--pub-key-file",
        help=f"Path to public key file (or set {PUBKEY_FILE_ENV})",
    )

    args = parser.parse_args()

    if args.command == "self-test":
        self_test()
        sys.exit(0)

    if args.command == "generate-key":
        out_key = Path(args.out_key_file)
        if out_key.exists():
            print(f"ERROR: Refusing to overwrite existing key file: {out_key}", file=sys.stderr)
            sys.exit(1)
        seed = os.urandom(32)
        pub = public_key_from_seed(seed)
        out_key.parent.mkdir(parents=True, exist_ok=True)
        out_key.write_text(seed.hex() + "\n", encoding="utf-8")
        try:
            os.chmod(out_key, 0o600)
        except OSError as exc:
            print(f"WARN: Could not restrict permissions on {out_key}: {exc}", file=sys.stderr)
        if args.out_pub_file:
            out_pub = Path(args.out_pub_file)
            out_pub.parent.mkdir(parents=True, exist_ok=True)
            out_pub.write_text(pub.hex() + "\n", encoding="utf-8")
        print(f"Saved private key seed to: {out_key} (KEEP OFFLINE, DO NOT COMMIT)")
        print(f"Public Key (hex):          {pub.hex()}")
        sys.exit(0)

    if args.command == "sign":
        try:
            key_file = resolve_private_key_file(args.key_file)
            manifest_path = Path(args.manifest)
            sig_b64 = sign_manifest_file(manifest_path, key_file)
            print(f"Signed {manifest_path} (Signature: {sig_b64[:16]}...)")
            sys.exit(0)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(1)

    if args.command == "verify":
        try:
            pub = resolve_public_key_bytes(args.pub_key, args.pub_key_file)
            manifest_path = Path(args.manifest)
            valid = verify_manifest_file(manifest_path, pub)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            sys.exit(1)
        if valid:
            print("PASS: Manifest Ed25519 signature is valid.")
            sys.exit(0)
        print("FAIL: Manifest Ed25519 signature is INVALID!", file=sys.stderr)
        sys.exit(1)

    parser.print_help()


if __name__ == "__main__":
    main()
