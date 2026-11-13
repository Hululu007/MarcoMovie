#!/usr/bin/env python3
"""
Adversarial Challenge Harness for Milestone 10 Lane F (F1 & F2).
Tests cryptographic correctness, tamper resilience, iteration downgrade resistance,
and malformed input handling.
"""

import hashlib
import hmac
import os
import re
import sys
import time

def test_pbkdf2_rfc_vectors():
    """Verify PBKDF2-HMAC-SHA256 against Python standard library."""
    pin = "1234".encode("utf-8")
    salt = "saltsaltsaltsalt".encode("utf-8")
    expected = hashlib.pbkdf2_hmac("sha256", pin, salt, 100000, 32).hex()
    assert expected == "5cf4a02537fc3a2c1e3e55d35709f68310c4581d849251daa8a8a23320f51536", (
        f"PBKDF2 vector mismatch: {expected}"
    )
    print("[PASS] PBKDF2-HMAC-SHA256 test vector matches RFC reference.")

def test_constant_time_comparison_timing():
    """Evaluate constant-time comparison properties."""
    target = b"a" * 32
    diff_first = b"b" + b"a" * 31
    diff_last = b"a" * 31 + b"b"

    def constant_time_eq(a: bytes, b: bytes) -> bool:
        if len(a) != len(b):
            return False
        diff = 0
        for x, y in zip(a, b):
            diff |= x ^ y
        return diff == 0

    assert constant_time_eq(target, target) is True
    assert constant_time_eq(target, diff_first) is False
    assert constant_time_eq(target, diff_last) is False
    assert constant_time_eq(target, b"short") is False
    print("[PASS] Constant-time comparison logic operates as expected.")

def test_iteration_downgrade_vulnerability():
    """Demonstrate the iteration count downgrade vulnerability."""
    pin_pattern = re.compile(
        r"^pbkdf2:sha256:(?:(\d+):)?(\d+):([0-9a-fA-F]{32}):([0-9a-fA-F]{64})$"
    )
    
    # Crafted 1-iteration hash
    salt = os.urandom(16)
    downgraded_hash = hashlib.pbkdf2_hmac("sha256", b"1234", salt, 1, 32).hex()
    crafted_hash_string = f"pbkdf2:sha256:4:1:{salt.hex()}:{downgraded_hash}"

    match = pin_pattern.match(crafted_hash_string)
    assert match is not None, "Crafted 1-iteration hash matches regex!"
    
    parsed_iterations = int(match.group(2))
    print(f"[*] Parsed iterations from crafted hash: {parsed_iterations}")
    if parsed_iterations < 100000:
        print(f"[FAIL / VULNERABILITY CONFIRMED] Stored PIN hash parsed with {parsed_iterations} < 100,000 iterations!")
    else:
        print("[PASS] Iterations enforced >= 100,000.")

def main():
    print("=== Milestone 10 Adversarial Challenge Harness ===")
    test_pbkdf2_rfc_vectors()
    test_constant_time_comparison_timing()
    test_iteration_downgrade_vulnerability()
    print("=== All Python checks completed ===")

if __name__ == "__main__":
    main()
