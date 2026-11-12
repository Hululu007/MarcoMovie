"""Update independently released platform packages without rendering the site.

The existing page is the template: package URLs, sizes and checksums inside
matching download cards change, and the existing changelog section receives
version-specific release notes. CSS and legacy Android update channels stay intact.
"""
import argparse
import html
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

from sync_movie_mirror import BASE, REPO, fetch, platform_asset
from platform_package_names import ALIASES as CLEAR_NAMES

SUFFIXES = {
    'ios': ('ios-unsigned.ipa',),
    'windows': ('windows-setup.exe', 'windows-x64.zip'),
    'macos': ('macos.zip',),
}
PLATFORM_LABELS = {
    'ios': 'iPhone / iPad', 'windows': 'Windows', 'macos': 'macOS',
    'android-tv': 'Android 电视', 'android-mobile': 'Android 手机 / 平板',
    'android-lite': 'Android Lite',
}
NOTE_SUFFIXES = {
    'android-tv.apk': 'android-tv', 'android-mobile.apk': 'android-mobile',
    'android-lite.apk': 'android-lite',
    'preview.apk': 'android-tv', 'mobile.apk': 'android-mobile',
    'lite.apk': 'android-lite', 'ios-unsigned.ipa': 'ios',
    'windows-setup.exe': 'windows', 'windows-x64.zip': 'windows',
    'macos.zip': 'macos',
}
NOTE_SUFFIXES.update({new: NOTE_SUFFIXES[old] for old, new in CLEAR_NAMES.items()})


def note_record(release):
    """Keep the published text verbatim; filenames/tags establish platform scope."""
    tag = release.get('tag_name', '')
    match = re.fullmatch(r'(?:(ios|windows|macos|android-tv|android-mobile|android-lite)-)?v(\d+\.\d+\.\d+)(-preview)?', tag)
    if not match or release.get('draft') or not release.get('published_at'):
        return None
    platform, version, _ = match.groups()
    names = {asset.get('name') for asset in release.get('assets', [])}
    platforms = [platform] if platform else list(dict.fromkeys(
        p for suffix, p in NOTE_SUFFIXES.items()
        if f'MarcoMovie-{version}-{suffix}' in names))
    if not platforms:
        return None
    notes = release.get('body') or ''
    if not isinstance(notes, str) or len(notes.encode('utf-8')) > 128 * 1024:
        raise ValueError('Invalid release notes: ' + tag)
    return dict(tag=tag, version=version, platforms=platforms,
                published_at=release['published_at'], prerelease=bool(release.get('prerelease')),
                target_commitish=release.get('target_commitish', ''), notes=notes,
                release_url=f'https://github.com/{REPO}/releases/tag/{tag}')


def release_history(output, releases):
    """Retain older entries even when they fall outside GitHub's newest page."""
    path = output / 'updates/history.json'
    records = json.loads(path.read_text(encoding='utf-8'))['releases'] if path.exists() else []
    by_tag = {item['tag']: item for item in records}
    for release in releases:
        item = note_record(release)
        if item is not None:
            by_tag[item['tag']] = item
    records = sorted(by_tag.values(), key=lambda item: (item['published_at'], item['tag']), reverse=True)
    files = {}
    for item in records:
        # Validate saved names too: an on-disk index never supplies output paths.
        if not re.fullmatch(r'(?:(?:ios|windows|macos|android-tv|android-mobile|android-lite)-)?v\d+\.\d+\.\d+(?:-preview)?', item['tag']):
            raise ValueError('Invalid archived release tag')
        text = item['notes'] if item['notes'].strip() else '该历史版本未提供更新说明。'
        files[f'updates/history/{item["tag"]}.md'] = (text + '\n').encode('utf-8')
    if records:
        files['updates/history.json'] = (json.dumps(dict(schema=1, releases=records), ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    return records, files


NOTE_CATEGORIES = (
    ('问题修复与优化', ('修复', '报错', '异常', '崩溃', '闪退', '观看历史', '观影记录', '桌面快捷方式', '桌面图标')),
    ('片源与播放', ('片源', '线路', '网盘', '玩偶', '夸克', '百度', '阿里', 'UC', '播放', '片头', '片尾', '常显时间', '解码', '直播', '弹幕', '字幕', '插件', '嗅探')),
    ('界面与交互', ('界面', '海报', '首页', '筛选', '分类', '窗口', '标题栏', '沉浸式', '中文', '安装程序', '安装向导', '闪烁', '加载更多', '导航', '遥控', '设置页')),
    ('功能与同步', ('同步', 'WebDAV', '局域网', '收藏', '新增', '支持', '引入', '升级')),
)
TECH_PAREN_RE = re.compile(r'[（(][^）)]*(?:`[^`]+`|[A-Za-z_][A-Za-z0-9_./:-]{3,}|SHA-256|MKCOL)[^）)]*[）)]')
META_SENTENCE_RE = re.compile(r'^(?:发布日期|应用版本|版本代码|构建号|最低系统要求)[：:][^。\n]*[。.]?\s*')


def _clean_note_line(raw):
    text = TECH_PAREN_RE.sub('', raw)
    text = re.sub(r'\s+', ' ', text).strip()
    return text


def _condense_note_item(text, limit=92):
    s = text.strip()
    if not s:
        return ''
    if len(s) <= limit:
        return s.rstrip('。；;，, ')
    for sep in ('；', '。'):
        idx = s.find(sep)
        if 14 <= idx <= limit + 8:
            s = s[:idx]
            break
    if len(s) > limit:
        comma = s.rfind('，', 0, limit)
        s = s[:comma] if comma >= limit // 2 else (s[:limit - 1] + '…')
    return s.rstrip('。；;，, ')


def summarize_notes(notes):
    """Automatically condense, deduplicate, and group verbose release notes."""
    raw = (notes or '').strip()
    if not raw:
        return ''
    overview = ''
    skip_section = False
    in_verification = False
    pending_topic = ''
    buckets = {title: [] for title, _ in NOTE_CATEGORIES}
    buckets['注意事项'] = []
    seen = set()

    def add_unique(cat, item):
        plain = re.sub(r'\[([^\]\n]+)\]\(([^)\s]+)\)', r'\1', item).replace('**', '').replace('`', '')
        norm = re.sub(r'[\s·•:：,，.。!！?？;；()（）\[\]【】「」]', '', plain.lower())
        if norm and norm not in seen:
            seen.add(norm)
            buckets[cat].append(item)

    def classify(item):
        plain = item.replace('**', '').replace('`', '')
        if plain.startswith(('已知限制：', '已知限制:', '注意事项：')):
            return '注意事项'
        for cat, keywords in NOTE_CATEGORIES:
            if cat == '问题修复与优化':
                if plain.startswith('修复') or any(k in plain for k in keywords[1:]):
                    return cat
            elif any(k in plain for k in keywords):
                return cat
        return '问题修复与优化'

    for raw_line in notes.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        heading = re.match(r'^#{1,6}\s+(.+)$', line)
        if heading:
            h = heading[1].replace('**', '').replace('`', '').strip()
            h_low = h.lower()
            pending_topic = ''
            if h_low.startswith('marco movie') or re.match(r'^v?\d+\.\d+\.\d+', h_low) or h in ('更新内容', '核心修复与优化') or h_low == 'changes':
                skip_section = False
                in_verification = False
                continue
            if any(k in h for k in ('包信息', '构建记录', '文件校验', '安装包校验')) or 'checksum' in h_low or 'artifact' in h_low:
                skip_section = True
                in_verification = False
                continue
            if any(k in h for k in ('验证范围', '测试记录', '自动化验证')):
                skip_section = True
                in_verification = True
                continue
            skip_section = False
            in_verification = False
            continue
        numbered_bold = re.match(r'^\d+[.)、]\s*\*\*(.+?)\*\*\s*$', line)
        if numbered_bold:
            if not skip_section:
                pending_topic = numbered_bold[1].replace('`', '').strip()
            continue
        bullet = re.match(r'^(?:[-*•]|\d+[.)])\s+(.+)$', line)
        content = bullet[1].strip() if bullet else line
        plain_check = content.replace('**', '').replace('`', '')
        if plain_check.startswith(('已知限制：', '已知限制:', '注意事项：')):
            add_unique('注意事项', _condense_note_item(_clean_note_line(content), 96))
            continue
        if skip_section:
            if in_verification and '已知限制' in plain_check:
                add_unique('注意事项', _condense_note_item(_clean_note_line(content), 96))
            continue
        low_check = plain_check.lower()
        if (plain_check.startswith(('发布日期：', '发布日期:'))
                or low_check.startswith(('platform:', '- platform:', 'commit:', '- commit:'))
                or 'sha-256' in low_check or 'sha256:' in low_check
                or '构建提交' in plain_check or '对应源码包' in plain_check
                or plain_check.startswith('通过公共内容守卫检查')
                or (plain_check.startswith('自动化与') and '实机验收' in plain_check)
                or (plain_check.startswith('未签名 IPA 支持巨魔') and '长期可用性承诺' in plain_check)):
            rest = content
            while True:
                m_meta = META_SENTENCE_RE.match(rest)
                if not m_meta:
                    break
                rest = rest[m_meta.end():].strip()
            if rest and not overview:
                overview = _condense_note_item(_clean_note_line(rest), 96)
            continue
        if not bullet and not overview and sum(len(v) for v in buckets.values()) == 0 and plain_check.startswith('本次更新'):
            overview = _condense_note_item(_clean_note_line(content), 96)
            continue
        cleaned = _clean_note_line(content)
        if not cleaned:
            continue
        if pending_topic and not cleaned.replace('**', '').startswith(pending_topic):
            if '：' not in cleaned and ':' not in cleaned:
                cleaned = f'**{pending_topic}**：{cleaned}'
            pending_topic = ''
        condensed = _condense_note_item(cleaned, 92)
        if condensed:
            add_unique(classify(condensed), condensed)

    ordered_titles = ['片源与播放', '界面与交互', '功能与同步', '问题修复与优化', '注意事项']
    non_empty = [(t, buckets[t]) for t in ordered_titles if buckets[t]]
    total = sum(len(items) for _, items in non_empty)
    if not non_empty:
        return overview or raw
    if total == 1 and not overview:
        return non_empty[0][1][0]
    out = []
    if overview:
        out.append(overview)
        out.append('')
    show_headers = len(non_empty) > 1 or total >= 3
    for title, items in non_empty:
        if show_headers:
            out.append(f'### {title}')
        for item in items:
            out.append(f'- {item}')
        out.append('')
    return '\n'.join(out).strip()


def render_notes(notes):
    """A small escaped Markdown subset, with no raw HTML or executable URLs."""
    def inline(text):
        result, start = [], 0
        for token in re.finditer(r'`([^`\n]+)`|\*\*([^*\n]+)\*\*|\[([^\]\n]+)\]\(([^\s)]+)\)', text):
            result.append(html.escape(text[start:token.start()]))
            if token[1] is not None:
                result.append('<code>' + html.escape(token[1]) + '</code>')
            elif token[2] is not None:
                result.append('<strong>' + html.escape(token[2]) + '</strong>')
            else:
                try:
                    url = urlsplit(token[4])
                    safe = url.scheme == 'https' and url.hostname and not url.username and not url.password
                except ValueError:
                    safe = False
                if safe:
                    result.append('<a href="' + html.escape(token[4], quote=True) + '">' + html.escape(token[3]) + '</a>')
                else:
                    result.append(html.escape(token[0]))
            start = token.end()
        result.append(html.escape(text[start:]))
        return ''.join(result)

    blocks, paragraph, listing = [], [], None
    def flush():
        if paragraph:
            blocks.append('<p>' + '<br>'.join(map(inline, paragraph)) + '</p>')
            paragraph.clear()
    for raw in notes.splitlines() + ['']:
        line = raw.strip()
        heading = re.match(r'^#{1,6}\s+(.+)$', line)
        bullet = re.match(r'^(?:([-*])|\d+[.)])\s+(.+)$', line)
        if listing and not bullet:
            blocks.append('</' + listing + '>')
            listing = None
        if heading:
            flush()
            blocks.append('<h4>' + inline(heading[1]) + '</h4>')
        elif bullet:
            flush()
            kind = 'ul' if bullet[1] else 'ol'
            if listing != kind:
                if listing:
                    blocks.append('</' + listing + '>')
                start = re.match(r'^(\d+)', line) if kind == 'ol' else None
                blocks.append('<' + kind + (' start="' + start[1] + '"' if start and start[1] != '1' else '') + '>')
                listing = kind
            blocks.append('<li>' + inline(bullet[2]) + '</li>')
        elif line:
            paragraph.append(line)
        else:
            flush()
    return ''.join(blocks)


def patch_notes(page, records):
    if not records:
        return page
    sections = list(re.finditer(r'(<section\b[^>]*\bid="changelog"[^>]*>).*?</section>', page, re.S))
    if len(sections) != 1:
        raise ValueError('Expected exactly one existing changelog section')
    seen, current, archive = set(), [], []
    for item in records:
        platforms = item['platforms']
        latest = not item['prerelease'] and any(p not in seen for p in platforms)
        if not item['prerelease']:
            seen.update(platforms)
        platform_names = '、'.join(PLATFORM_LABELS[p] for p in platforms)
        label = (platform_names if len(platforms) < 3 else '多平台') + ' · ' + item['version']
        if item['prerelease']:
            label += ' · 预览版'
        escaped = html.escape
        note = summarize_notes(item['notes']) if item['notes'].strip() else '该历史版本未提供更新说明。'
        entry = (
            '<details class="release-entry" data-platforms="' + ' '.join(platforms) + '"'
            + (' open' if latest and not current else '') + '><summary><span>' + escaped(label) + '</span>'
            '<span class="release-date">' + escaped(item['published_at'][:10]) + '</span></summary>'
            '<div class="release-content"><p class="release-platforms">适用：' + escaped(platform_names) + '</p><p class="release-links">'
            '<a href="' + escaped(item['release_url'], quote=True) + '">GitHub 发布记录</a> · '
            '<a href="updates/history/' + escaped(item['tag']) + '.md">完整更新说明</a></p>'
            + render_notes(note) + '</div></details>')
        (current if latest else archive).append(entry)
    section = sections[0]
    options = '<option value="all">全部平台</option>' + ''.join(
        '<option value="' + key + '">' + value + '</option>' for key, value in PLATFORM_LABELS.items())
    content = (section[1] + '<div class="section-heading"><div><p class="eyebrow">RELEASE NOTES</p><h2>版本更新</h2></div>'
               '<label class="filter-control" hidden>查看平台<select id="release-platform" aria-label="查看平台">' + options + '</select></label></div>'
               '<p class="sub">各端独立更新。展开对应版本，查看新增、修复和已知限制。</p>'
               + '<div class="current-releases">' + '\n'.join(current) + '</div>'
               + ('<details class="release-archive"><summary>历史版本 <span>' + str(len(archive)) + ' 个版本</span></summary>'
                  + '\n'.join(archive) + '</details>' if archive else '')
               + '<p id="release-empty" class="sub" hidden>该平台暂无发布记录。</p></section>')
    return page[:section.start()] + content + page[section.end():]


def version_key(version):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Invalid platform version')
    return tuple(map(int, version.split('.')))


def choose_platform(releases, platform):
    candidates = []
    for release in releases:
        match = re.fullmatch(re.escape(platform) + r'-v(\d+\.\d+\.\d+)', release.get('tag_name', ''))
        if match and not release.get('draft') and not release.get('prerelease') and release.get('published_at'):
            candidates.append((version_key(match[1]), release))
    return max(candidates, key=lambda item: item[0])[1] if candidates else None


def patch_card(page, suffix, package):
    aliases = {'android-tv.apk': 'preview.apk', 'android-mobile.apk': 'mobile.apk',
               'android-lite.apk': 'lite.apk'}
    aliases.update(CLEAR_NAMES)
    aliases.update({new: old for old, new in CLEAR_NAMES.items()})
    endings = [suffix] + ([aliases[suffix]] if suffix in aliases else [])
    name_pattern = r'MarcoMovie-\d+\.\d+\.\d+-(?:' + '|'.join(map(re.escape, endings)) + ')'
    cards = list(re.finditer(r'<div class="dl"(?:\s+[^>]*)?>.*?</div>', page, re.S))
    matches = [card for card in cards if re.search(name_pattern, card[0])]
    if len(matches) != 1:
        raise ValueError('Expected exactly one existing download card: ' + suffix)
    card = matches[0]
    replacement, links = re.subn(
        r'href="[^"<>]*' + name_pattern + r'(\.sha256)?"',
        lambda match: 'href="' + html.escape(package['url'], quote=True) + (match[1] or '') + '"',
        card[0])
    if links != 2:
        raise ValueError('Expected package and checksum links: ' + suffix)
    replacement, hashes = re.subn(r'(SHA-256：)[a-f0-9]{64}',
                                 lambda match: match[1] + package['sha256'], replacement)
    replacement, sizes = re.subn(r'\d+(?:\.\d+)? MB', f'{package["size"] / 1024 / 1024:.1f} MB', replacement)
    if hashes != 1 or sizes != 1:
        raise ValueError('Missing existing checksum or size: ' + suffix)
    # New layout exposes the package version; older templates remain supported.
    version = re.search(r'MarcoMovie-(\d+\.\d+\.\d+)-', package['url'])
    if version:
        replacement = re.sub(r'(<span class="package-version">)[^<]*(</span>)',
                             lambda m: m[1] + version[1] + m[2], replacement)
    return page[:card.start()] + replacement + page[card.end():]


def sync(output, releases=None):
    output = Path(output)
    original = (output / 'index.html').read_bytes()
    page = original.decode('utf-8')
    if releases is None:
        releases = json.loads(fetch(f'https://api.github.com/repos/{REPO}/releases?per_page=100', 4 * 1024 * 1024))
    from android_update_packages import plan as android_plan
    files, versions, android_cards = android_plan(output, releases)
    for platform, package in android_cards.items():
        page = patch_card(page, platform + '.apk', package)
    for platform, suffixes in SUFFIXES.items():
        release = choose_platform(releases, platform)
        if release is None:
            continue
        if not isinstance(release.get('body'), str) or not release['body'].strip():
            raise ValueError('Published platform release is missing update notes: ' + platform)
        version = release['tag_name'].split('-v', 1)[1]
        packages = {}
        names = {asset.get('name') for asset in release.get('assets', [])}
        for suffix in suffixes:
            preferred = CLEAR_NAMES.get(suffix, suffix)
            name = f'MarcoMovie-{version}-{preferred}'
            if name not in names:
                name = f'MarcoMovie-{version}-{suffix}'
            href, size, digest, body = platform_asset(release, name, output)
            package = dict(size=size, sha256=digest, url=href if href.startswith('https://') else BASE + name)
            packages[name] = package
            if body is not None:
                files[name] = body
                files[name + '.sha256'] = (digest + '  ' + name + '\n').encode('ascii')
            page = patch_card(page, suffix, package)
        feed = dict(schema=1, platform=platform, versionName=version, prerelease=False,
                    notes=release.get('body') or '', packages=packages,
                    release_url=f'https://github.com/{REPO}/releases/tag/{release["tag_name"]}')
        if platform == 'windows':
            # Installed 0.5.x clients require this exact legacy filename. The
            # public card can use the clearer name, but the update channel must
            # retain a verified, byte-identical alias until those clients migrate.
            legacy_name = f'MarcoMovie-{version}-windows-setup.exe'
            setup = next(package for name, package in packages.items()
                         if name.endswith(('-windows-x64-setup.exe', '-windows-setup.exe')))
            if legacy_name not in packages:
                if legacy_name not in names:
                    raise ValueError('Missing Windows updater compatibility alias')
                href, size, digest, body = platform_asset(release, legacy_name, output)
                if size != setup['size'] or digest != setup['sha256']:
                    raise ValueError('Windows updater alias differs from the public installer')
                packages[legacy_name] = dict(size=size, sha256=digest,
                                            url=href if href.startswith('https://') else BASE + legacy_name)
                if body is not None:
                    files[legacy_name] = body
                    files[legacy_name + '.sha256'] = (digest + '  ' + legacy_name + '\n').encode('ascii')
            feed['windows'] = packages[legacy_name]
        path = f'updates/{platform}.json'
        previous_path = output / path
        if previous_path.exists():
            previous = json.loads(previous_path.read_text(encoding='utf-8'))
            if version_key(previous['versionName']) > version_key(version):
                raise ValueError('Refusing platform rollback: ' + platform)
            if previous['versionName'] == version and previous['packages'] != packages:
                raise ValueError('Refusing to replace a published package: ' + platform)
        files[path] = (json.dumps(feed, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
        versions[platform] = version
    history, note_files = release_history(output, releases)
    files.update(note_files)
    page = patch_notes(page, history)
    files['index.html'] = page.encode('utf-8')
    # Nothing is written until every release/card has validated. Git publishes
    # the complete snapshot; never rewrite a previously published binary.
    for name, body in files.items():
        target = output / name
        if target.exists() and target.suffix in ('.ipa', '.exe', '.zip', '.apk') and target.read_bytes() != body:
            raise ValueError('Immutable package differs: ' + name)
    for name, body in files.items():
        target = output / name
        if not target.exists() or target.read_bytes() != body:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(body)
    return versions


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(sync(args.output), ensure_ascii=False))
