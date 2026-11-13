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


def self_test() -> None:
    # RFC 8032 7.1 Test Vector 1
    seed1 = bytes.fromhex(
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    )
    pub1 = public_key_from_seed(seed1)
    expected_pub1 = bytes.fromhex(
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    )
    assert pub1 == expected_pub1, f"Pubkey 1 mismatch: {pub1.hex()}"
    sig1 = sign(seed1, b"")
    expected_sig1 = bytes.fromhex(
        "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"
    )
    assert sig1 == expected_sig1, f"Sig 1 mismatch: {sig1.hex()}"
    assert verify(pub1, b"", sig1), "Sig 1 verify failed"
    assert not verify(
        pub1, b"", bytearray(sig1[:-1]) + bytes([sig1[-1] ^ 1])
    ), "Tampered sig passed"

    # RFC 8032 Test Vector 2 (message: 0x72)
    seed2 = bytes.fromhex(
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
    )
    pub2 = public_key_from_seed(seed2)
    expected_pub2 = bytes.fromhex(
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
    )
    assert pub2 == expected_pub2, f"Pubkey 2 mismatch: {pub2.hex()}"
    sig2 = sign(seed2, b"\x72")
    expected_sig2 = bytes.fromhex(
        "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"
    )
    assert sig2 == expected_sig2, f"Sig 2 mismatch: {sig2.hex()}"
    assert verify(pub2, b"\x72", sig2), "Sig 2 verify failed"

    print("ALL RFC 8032 TEST VECTORS PASSED!")


def main():
    parser = argparse.ArgumentParser(
        description="RFC 8032 Ed25519 Manifest Signer & Verifier"
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("self-test", help="Run RFC 8032 self test")

    gen_cmd = sub.add_parser("generate-key", help="Generate Ed25519 keypair")

    sign_cmd = sub.add_parser("sign", help="Sign update manifest JSON")
    sign_cmd.add_argument("manifest", help="Path to manifest JSON file")
    sign_cmd.add_argument(
        "--key", required=True, help="Private key seed hex (32 bytes)"
    )

    verify_cmd = sub.add_parser("verify", help="Verify update manifest JSON")
    verify_cmd.add_argument("manifest", help="Path to manifest JSON file")
    verify_cmd.add_argument(
        "--key", required=True, help="Public key hex (32 bytes)"
    )

    args = parser.parse_args()

    if args.command == "self-test":
        self_test()
        sys.exit(0)

    if args.command == "generate-key":
        seed = os.urandom(32)
        pub = public_key_from_seed(seed)
        print(f"Private Key (seed hex): {seed.hex()}")
        print(f"Public Key (hex):        {pub.hex()}")
        sys.exit(0)

    if args.command == "sign":
        manifest_path = Path(args.manifest)
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        payload = (
            data["payload"]
            if "payload" in data and isinstance(data["payload"], dict)
            else {k: v for k, v in data.items() if k not in ("signature", "sig")}
        )
        canonical = canonicalize_json(payload)
        seed = bytes.fromhex(args.key)
        sig = sign(seed, canonical.encode("utf-8"))
        sig_b64 = base64.b64encode(sig).decode("ascii")
        data["signature"] = sig_b64
        manifest_path.write_text(
            json.dumps(data, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"Signed {manifest_path} (Signature: {sig_b64[:16]}...)")
        sys.exit(0)

    if args.command == "verify":
        manifest_path = Path(args.manifest)
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        sig_b64 = data.get("signature") or data.get("sig")
        if not sig_b64:
            print("ERROR: No signature field found in manifest")
            sys.exit(1)
        sig = base64.b64decode(sig_b64)
        payload = (
            data["payload"]
            if "payload" in data and isinstance(data["payload"], dict)
            else {k: v for k, v in data.items() if k not in ("signature", "sig")}
        )
        canonical = canonicalize_json(payload)
        pub = bytes.fromhex(args.key)
        valid = verify(pub, canonical.encode("utf-8"), sig)
        if valid:
            print("PASS: Manifest Ed25519 signature is valid.")
            sys.exit(0)
        else:
            print("FAIL: Manifest Ed25519 signature is INVALID!")
            sys.exit(1)

    parser.print_help()


if __name__ == "__main__":
    main()
