"""Create descriptive installer names while retaining old updater-compatible bytes."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess

ALIASES = {
    'windows-setup.exe': 'windows-x64-setup.exe',
    'windows-x64.zip': 'windows-x64-portable.zip',
    'macos.zip': 'macos-desktop.zip',
    'ios-unsigned.ipa': 'ios-iphone-ipad-unsigned.ipa',
}
PLATFORMS = {
    'windows': ('windows-setup.exe', 'windows-x64.zip'),
    'macos': ('macos.zip',),
    'ios': ('ios-unsigned.ipa',),
}
MSG_PLACEHOLDER_RE = re.compile(r'%[1-9]')


def filter_isl_messages(chinese_isl_text, default_isl_text):
    """Keep [LangOptions] and only [Messages] keys valid in the installed Default.isl."""
    if not default_isl_text:
        return chinese_isl_text
    valid_msgs = {}
    in_default_msgs = False
    for raw_line in default_isl_text.splitlines():
        s = raw_line.strip()
        if s.startswith('[') and s.endswith(']'):
            in_default_msgs = s.lower() == '[messages]'
            continue
        if in_default_msgs and '=' in raw_line and not s.startswith(';'):
            k, v = raw_line.split('=', 1)
            valid_msgs[k.strip()] = set(MSG_PLACEHOLDER_RE.findall(v))
    if not valid_msgs:
        return chinese_isl_text

    out_lines = []
    in_cn_msgs = False
    for raw_line in chinese_isl_text.splitlines():
        s = raw_line.strip()
        if s.startswith('[') and s.endswith(']'):
            in_cn_msgs = s.lower() == '[messages]'
            out_lines.append(raw_line)
            continue
        if in_cn_msgs and '=' in raw_line and not s.startswith(';'):
            k, v = raw_line.split('=', 1)
            key = k.strip()
            if key not in valid_msgs:
                continue
            if not set(MSG_PLACEHOLDER_RE.findall(v)).issubset(valid_msgs[key]):
                continue
        out_lines.append(raw_line)
    return '\n'.join(out_lines) + '\n'


def windows_installer_script(version, setup_base, isl_rel_path=r'installer\ChineseSimplified.build.isl'):
    """Render the single installer template used by packaging and its preflight."""
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version):
        raise ValueError('Invalid package version')
    if setup_base != f'MarcoMovie-{version}-windows-setup':
        raise ValueError('Installer filename must match its version')
    template = Path(__file__).with_name('windows_installer.iss').read_text(encoding='utf-8')
    values = {
        'AppVersion': version,
        'ReleaseDir': r'build\windows\x64\runner\Release',
        'IconFile': r'windows\runner\resources\app_icon.ico',
        'PackageDir': 'dist',
        'ChineseMessagesFile': isl_rel_path,
    }
    for name, value in values.items():
        template = template.replace('{#' + name + '}', value)
    return template


def find_inno_setup_compiler():
    override = os.environ.get('MARCOMOVIE_ISCC', '').strip()
    if override:
        p = Path(override)
        return p if p.is_file() else None
    for env_key in ('ProgramFiles(x86)', 'ProgramFiles'):
        root = os.environ.get(env_key, '').strip()
        if root:
            candidate = Path(root) / 'Inno Setup 6' / 'ISCC.exe'
            if candidate.is_file():
                return candidate
    return None


def rebuild_windows_setup_if_runner_present(folder, version, iscc_path=None):
    """Rebuild Windows Setup with UTF-8-BOM Simplified Chinese UI & upgrade shortcut guard."""
    folder = Path(folder).resolve()
    flutter_dir = folder.parent
    release_exe = flutter_dir / 'build' / 'windows' / 'x64' / 'runner' / 'Release' / 'marco_movie.exe'
    isl_src = flutter_dir / 'installer' / 'ChineseSimplified.isl'
    iscc = Path(iscc_path) if iscc_path else find_inno_setup_compiler()
    if not (release_exe.is_file() and isl_src.is_file() and iscc and iscc.is_file()):
        return False

    default_isl = iscc.parent / 'Default.isl'
    default_text = default_isl.read_text(encoding='utf-8-sig', errors='replace') if default_isl.is_file() else ''
    cn_text = isl_src.read_text(encoding='utf-8-sig')
    filtered_isl = filter_isl_messages(cn_text, default_text)
    isl_build = flutter_dir / 'installer' / 'ChineseSimplified.build.isl'
    isl_build.write_text(filtered_isl, encoding='utf-8-sig')

    setup_base = f'MarcoMovie-{version}-windows-setup'
    setup_path = folder / f'{setup_base}.exe'
    iss_path = flutter_dir / 'installer.iss'
    iss_path.write_text(windows_installer_script(version, setup_base), encoding='utf-8-sig')

    subprocess.run([str(iscc), str(iss_path)], cwd=str(flutter_dir), check=True)
    if not setup_path.is_file() or setup_path.stat().st_size == 0:
        raise RuntimeError(f'ISCC did not produce non-empty installer: {setup_path}')

    digest = hashlib.sha256(setup_path.read_bytes()).hexdigest()
    setup_path.with_name(setup_path.name + '.sha256').write_text(
        f'{digest}  {setup_path.name}\n',
        encoding='ascii',
    )
    alias_path = folder / f'MarcoMovie-{version}-{ALIASES["windows-setup.exe"]}'
    if alias_path.exists():
        alias_path.unlink()
    return True


def clear_names(folder, version, platform):
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?', version):
        raise ValueError('Invalid package version')
    if platform not in PLATFORMS:
        raise ValueError('Unknown platform')
    folder = Path(folder)
    planned = []
    for old in PLATFORMS[platform]:
        source = folder / f'MarcoMovie-{version}-{old}'
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if source.stat().st_size == 0 or source.with_name(source.name + '.sha256').read_text().split()[0] != digest:
            raise ValueError('Original package checksum mismatch')
        target = folder / f'MarcoMovie-{version}-{ALIASES[old]}'
        if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() != digest:
            raise ValueError('Refusing to overwrite a different named package')
        planned.append((source, target, digest))
    for source, target, digest in planned:
        shutil.copyfile(source, target)
        target.with_name(target.name + '.sha256').write_text(digest + '  ' + target.name + '\n', encoding='ascii')
    return [target for _, target, _ in planned]


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--platform', choices=PLATFORMS, required=True)
    args = parser.parse_args()
    if args.platform == 'windows':
        rebuild_windows_setup_if_runner_present(args.folder, args.version)
    for path in clear_names(args.folder, args.version, args.platform):
        print(path.name)
