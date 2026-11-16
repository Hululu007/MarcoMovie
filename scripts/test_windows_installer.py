"""Compile the real installer with a tiny fixture before the expensive app build."""
from pathlib import Path
import argparse
import hashlib
import shutil
import struct
import tempfile
import zipfile

from platform_package_names import rebuild_windows_setup_if_runner_present, clear_names


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--compiler', required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='marco-installer-preflight-') as name:
        work = Path(name).resolve()
        assert work.is_relative_to(Path(tempfile.gettempdir()).resolve())
        source = work / 'flutter/build/windows/x64/runner/Release'
        source.mkdir(parents=True)
        (source / 'marco_movie.exe').write_text('Compiler validation fixture only; never execute.', encoding='utf-8')
        installer = work / 'flutter/installer'
        installer.mkdir()
        shutil.copy2(repo / 'flutter/installer/ChineseSimplified.isl', installer)
        resources = work / 'flutter/windows/runner/resources'
        resources.mkdir(parents=True)
        output = work / 'flutter/dist'
        output.mkdir()
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
        shutil.copy2(icon, resources / 'app_icon.ico')
        portable = output / 'MarcoMovie-0.0.0-windows-x64.zip'
        with zipfile.ZipFile(portable, 'w') as package:
            package.write(source / 'marco_movie.exe', 'marco_movie.exe')
            package.write(icon, icon.name)
        digest = hashlib.sha256(portable.read_bytes()).hexdigest()
        portable.with_suffix('.zip.sha256').write_text(digest + '  ' + portable.name)
        assert rebuild_windows_setup_if_runner_present(output, '0.0.0', args.compiler)
        aliases = clear_names(output, '0.0.0', 'windows')
        assert len(aliases) == 2 and all(path.is_file() for path in aliases)
        assert aliases[0].read_bytes() == (output / 'MarcoMovie-0.0.0-windows-setup.exe').read_bytes()
    print('Windows installer script compiled successfully; fixture removed.')


if __name__ == '__main__':
    main()
