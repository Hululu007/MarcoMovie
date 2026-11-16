"""Compile the real installer with a tiny fixture before the expensive app build."""
from pathlib import Path
import argparse
import os
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compiler', required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='marco-installer-preflight-') as name:
        work = Path(name).resolve()
        assert work.is_relative_to(Path(tempfile.gettempdir()).resolve())
        source = work / 'input'
        source.mkdir()
        (source / 'preflight.txt').write_text('Compiler validation fixture only.', encoding='utf-8')
        # Use the approved brand frames, without relying on a generated runner.
        frames = [(size, (repo / f'flutter/brand/windows/{size}.png').read_bytes())
                  for size in (16, 32, 48, 256)]
        offset = 6 + 16 * len(frames)
        directory = bytearray(struct.pack('<HHH', 0, 1, len(frames)))
        for size, data in frames:
            directory += struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0,
                                     1, 32, len(data), offset)
            offset += len(data)
        icon = source / 'MarcoMovie-0.0.0.ico'
        icon.write_bytes(directory + b''.join(data for _, data in frames))
        subprocess.run([args.compiler, '/Qp', '/DAppVersion=0.0.0',
                        f'/DReleaseDir={source}', f'/DIconFile={icon}',
                        f'/DPackageDir={work / "output"}',
                        str(repo / 'scripts/windows_installer.iss')], check=True)
        assert (work / 'output/MarcoMovie-0.0.0-windows-setup.exe').is_file()
    print('Windows installer script compiled successfully; fixture removed.')


if __name__ == '__main__':
    main()
