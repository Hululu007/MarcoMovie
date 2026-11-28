"""Prepare pinned compile dependencies for JS normalization checks on a clean host."""
from pathlib import Path
import hashlib, json, urllib.request, zipfile
from prepare_android_platform import prepare

ROOT = Path(__file__).resolve().parents[1]
prepare()
REQUIRED = {'wrapper-android', 'wrapper-java', 'jsoup'}
import sys
editions = (
    (sys.argv[1],)
    if len(sys.argv) > 1 and sys.argv[1] in ('android-tv', 'android-mobile')
    else ('android-tv', 'android-mobile')
)
for edition in editions:
    module_dir = ROOT / edition
    found = set()
    for item in json.loads((module_dir / 'dependencies.json').read_text(encoding='utf-8')):
        pkg_name = item.get('name', '')
        if pkg_name not in REQUIRED:
            continue
        name = item['url'].rsplit('/', 1)[1]
        target = ROOT / 'tools/java-dependencies' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            target.write_bytes(urllib.request.urlopen(item['url'], timeout=60).read())
        if hashlib.sha256(target.read_bytes()).hexdigest() != item['sha256']:
            raise RuntimeError('Dependency checksum mismatch: ' + name)
        if target.suffix == '.aar':
            for dst_mod in ('android-tv', 'android-mobile'):
                output = ROOT / dst_mod / 'build/aar' / target.stem / 'classes.jar'
                output.parent.mkdir(parents=True, exist_ok=True)
                with zipfile.ZipFile(target) as archive:
                    output.write_bytes(archive.read('classes.jar'))
        found.add(pkg_name)
    missing = REQUIRED - found
    if missing:
        raise RuntimeError(
            'Missing dependency declarations in ' + edition + ': ' + ', '.join(sorted(missing))
        )
print('Pinned JS test compile dependencies ready')
