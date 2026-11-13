import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'sign_manifest.py'
APP_UPDATE = ROOT / 'flutter' / 'src' / 'core' / 'app_update.dart'


class SignManifestCliChecks(unittest.TestCase):
    def test_no_builtin_rfc8032_keys(self):
        script_text = SCRIPT.read_text(encoding='utf-8').lower()
        dart_text = APP_UPDATE.read_text(encoding='utf-8').lower()
        # RFC 8032 test vector 1 seed / public key must not be built in.
        self.assertNotIn('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60', script_text)
        self.assertNotIn('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', script_text)
        self.assertNotIn('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', dart_text)

    def test_cli_key_file_and_env_var_signing(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            priv_file = tmp_dir / 'offline.key'
            pub_file = tmp_dir / 'offline.pub'
            subprocess.run(
                [sys.executable, str(SCRIPT), 'generate-key',
                 '--out-key-file', str(priv_file),
                 '--out-pub-file', str(pub_file)],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertTrue(priv_file.is_file())
            self.assertTrue(pub_file.is_file())
            pub_hex = pub_file.read_text(encoding='utf-8').strip()
            self.assertEqual(len(pub_hex), 64)

            # 1. Sign via --key-file CLI argument
            m1 = tmp_dir / 'windows_cli.json'
            m1.write_text(json.dumps({
                'payload': {
                    'platform': 'windows',
                    'versionName': '0.5.30',
                }
            }), encoding='utf-8')
            subprocess.run(
                [sys.executable, str(SCRIPT), 'sign', str(m1), '--key-file', str(priv_file)],
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [sys.executable, str(SCRIPT), 'verify', str(m1), '--pub-key', pub_hex],
                check=True,
                capture_output=True,
                text=True,
            )

            # 2. Sign via MARCOMOVIE_SIGN_KEY_FILE environment variable
            m2 = tmp_dir / 'windows_env.json'
            m2.write_text(json.dumps({
                'platform': 'windows',
                'versionName': '0.5.31',
            }), encoding='utf-8')
            env = dict(os.environ, MARCOMOVIE_SIGN_KEY_FILE=str(priv_file))
            subprocess.run(
                [sys.executable, str(SCRIPT), 'sign', str(m2)],
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )
            subprocess.run(
                [sys.executable, str(SCRIPT), 'verify', str(m2), '--pub-key-file', str(pub_file)],
                check=True,
                capture_output=True,
                text=True,
            )

            # 3. Missing key file and env var must fail cleanly
            env_missing = {k: v for k, v in os.environ.items() if k != 'MARCOMOVIE_SIGN_KEY_FILE'}
            failed = subprocess.run(
                [sys.executable, str(SCRIPT), 'sign', str(m2)],
                env=env_missing,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(failed.returncode, 0)


if __name__ == '__main__':
    unittest.main()
