"""Run isolated synthetic + E2E tests strictly on the API 14 emulator. Never selects a physical TV/phone."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import ssl
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse
import zipfile

from build_lite import API14, BUILD, JDK, ROOT, SDK, exe, run

sys.path.insert(0, str(ROOT / 'tools/lite-test'))

ADB = os.environ.get('MARCOMOVIE_ADB', 'adb')
PACKAGE = 'com.pilipala.marcomovie.lite'
TEST_PACKAGE = 'com.pilipala.marcomovie.lite.test'

SERVER_STOP_EVENT = threading.Event()
REQUEST_LOG_LOCK = threading.Lock()
REQUEST_LOGS = []
ALL_REQUEST_LOGS = []


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(65536), b''):
            h.update(chunk)
    return h.hexdigest()


def adb_cmd(serial: str, *args, timeout: int = 180) -> str:
    if not serial.startswith('emulator-'):
        raise RuntimeError(f'Refusing to target non-emulator serial: {serial}')
    return subprocess.check_output(
        [ADB, '-s', serial, *map(str, args)],
        timeout=timeout,
        stderr=subprocess.STDOUT,
    ).decode('utf-8', errors='replace')


def default_apk_path(candidate: bool) -> Path:
    meta = json.loads((ROOT / 'lite/edition-versions.json').read_text(encoding='utf-8'))
    ver = meta['android-lite']['versionName']
    from android_package_names import package_name
    folder = ROOT / ('verification/private/lite-candidate' if candidate else 'dist/lite')
    return folder / package_name(ver, 'lite')


def verify_installed_apk(serial: str, expected_apk: Path) -> dict:
    expected_sha = sha256_file(expected_apk)
    dumpsys = adb_cmd(serial, 'shell', 'dumpsys', 'package', PACKAGE)
    vc_m = re.search(r'versionCode=(\d+)', dumpsys)
    vn_m = re.search(r'versionName=([^\s]+)', dumpsys)
    version_code = int(vc_m.group(1)) if vc_m else -1
    version_name = vn_m.group(1) if vn_m else ''

    pm_path_out = adb_cmd(serial, 'shell', 'pm', 'path', PACKAGE).strip()
    device_apk_path = ''
    for line in pm_path_out.splitlines():
        if line.startswith('package:'):
            device_apk_path = line.split('package:', 1)[1].strip()
            break
    if not device_apk_path:
        raise RuntimeError(f'Failed to resolve installed package path: {pm_path_out}')

    with tempfile.TemporaryDirectory() as td:
        pulled = Path(td) / 'installed.apk'
        adb_cmd(serial, 'pull', device_apk_path, str(pulled))
        installed_sha = sha256_file(pulled)

    if installed_sha != expected_sha:
        raise RuntimeError(
            f'Installed APK SHA-256 mismatch! expected={expected_sha}, on_device={installed_sha}'
        )
    return {
        'package': PACKAGE,
        'apk_path': str(expected_apk.resolve()),
        'device_apk_path': device_apk_path,
        'version_name': version_name,
        'version_code': version_code,
        'expected_sha256': expected_sha,
        'installed_sha256': installed_sha,
        'sha256_match': True,
    }


def ensure_media_fixtures() -> Path:
    media_dir = ROOT / 'verification/private/lite'
    media_dir.mkdir(parents=True, exist_ok=True)
    baseline = media_dir / 'baseline.mp4'
    if not baseline.exists():
        subprocess.run(
            [
                'ffmpeg', '-v', 'error',
                '-f', 'lavfi', '-i', 'testsrc2=size=480x270:rate=24',
                '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=44100',
                '-t', '40',
                '-c:v', 'libx264', '-profile:v', 'baseline', '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart',
                str(baseline),
            ],
            check=True,
        )
    video2 = media_dir / 'video2.mp4'
    if not video2.exists():
        subprocess.run(
            [
                'ffmpeg', '-v', 'error',
                '-f', 'lavfi', '-i', 'testsrc2=size=480x270:rate=24',
                '-f', 'lavfi', '-i', 'sine=frequency=660:sample_rate=44100',
                '-t', '25',
                '-c:v', 'libx264', '-profile:v', 'baseline', '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart',
                str(video2),
            ],
            check=True,
        )
    short_live = media_dir / 'short-live.mp4'
    if not short_live.exists():
        subprocess.run(
            [
                'ffmpeg', '-v', 'error',
                '-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
                '-f', 'lavfi', '-i', 'sine=frequency=880:sample_rate=44100',
                '-t', '3',
                '-c:v', 'libx264', '-profile:v', 'baseline', '-pix_fmt', 'yuv420p',
                '-c:a', 'aac', '-ac', '2', '-movflags', '+faststart',
                str(short_live),
            ],
            check=True,
        )
    if not (media_dir / 'stream.m3u8').exists():
        subprocess.run(
            [
                'ffmpeg', '-v', 'error',
                '-i', str(baseline),
                '-c:v', 'libx264', '-profile:v', 'baseline', '-g', '48',
                '-c:a', 'copy', '-hls_time', '2', '-hls_list_size', '0',
                '-hls_segment_filename', str(media_dir / 'segment%d.ts'),
                str(media_dir / 'stream.m3u8'),
            ],
            check=True,
        )
    return media_dir


def build_fixture_configs() -> dict:
    base = 'http://10.0.2.2:8773'
    return {
        '/config': {
            'sites': [
                {'name': '合成测试', 'api': f'{base}/cms', 'type': 1},
                {'name': '插件兼容提示', 'api': 'csp_example', 'type': 3},
            ]
        },
        '/config-v059': {
            'sites': [
                {'key': 'site_a', 'name': '主站A', 'api': f'{base}/cms-a', 'type': 1, 'searchable': 1},
                {'key': 'site_b', 'name': '辅站B', 'api': f'{base}/cms-b', 'type': 1, 'searchable': 1},
                {'key': 'site_xml', 'name': '严格XML站', 'api': f'{base}/xml-strict', 'type': 0, 'searchable': 1},
                {'key': 'site_parse', 'name': '解析测试站', 'api': f'{base}/cms-parse', 'type': 1, 'parse': 1, 'searchable': 1},
                {'key': 'site_parse_empty', 'name': '空解析站', 'api': f'{base}/cms-parse-empty', 'type': 1, 'playUrl': f'json:{base}/parse-empty?url=', 'searchable': 0},
                {'key': 'site_fail', 'name': '故障源', 'api': f'{base}/cms-fail', 'type': 1, 'searchable': 1},
                {'key': 'site_py', 'name': 'Python插件源', 'api': 'py_douban', 'type': 4, 'searchable': 1},
                {'key': 'site_spider', 'name': 'Spider插件源', 'api': 'csp_Demo', 'type': 3, 'searchable': 1},
            ],
            'parses': [
                {'name': '本地JSON解析', 'type': 1, 'url': f'{base}/parse?url='},
            ],
            'lives': [
                {
                    'group': '测试直播组',
                    'channels': [
                        {'name': '短直播结束台', 'urls': [f'线路1${base}/short-live.mp4']},
                        {'name': '坏线快错台', 'urls': [f'坏线1${base}/bad-fast.mp4', f'好线2${base}/video2.mp4']},
                        {'name': '坏线无响应台', 'urls': [f'无响应1${base}/bad-hang.mp4', f'好线2${base}/stream.m3u8']},
                        {'name': '全坏线路台', 'urls': [f'坏线1${base}/bad-all-1.mp4', f'坏线2${base}/bad-all-2.mp4']},
                        {
                            'name': '双头直链台',
                            'urls': [
                                f'线路1${base}/hls-ref1/stream.m3u8|Referer=https://ref-line1.example/',
                                f'线路2${base}/hls-ref2/stream.m3u8|Referer=https://ref-line2.example/',
                            ],
                        },
                    ],
                }
            ],
        },
        '/config-only-b': {
            'sites': [
                {'key': 'site_only_b', 'name': '纯B新源', 'api': f'{base}/cms-only-b', 'type': 1, 'searchable': 1},
            ]
        },
        '/config-only-unsupported': {
            'sites': [
                {'key': 'only_sp', 'name': '外部Spider', 'api': 'csp_Only', 'type': 3},
                {'key': 'only_py', 'name': '外部Python', 'api': 'py_only', 'type': 4},
            ]
        },
        '/config-pure-live': {
            'lives': [
                {
                    'group': '内嵌双线组',
                    'channels': [
                        {
                            'name': '双头内嵌台',
                            'urls': [
                                f'线路1${base}/hls-ref1/stream.m3u8|Referer=https://ref-line1.example/',
                                f'线路2${base}/hls-ref2/stream.m3u8|Referer=https://ref-line2.example/',
                            ],
                        }
                    ],
                },
                {
                    'name': '重定向相对M3U',
                    'type': 0,
                    'url': f'{base}/live-redir-entry.m3u',
                },
            ]
        },
        '/config-dup-key': {
            'sites': [
                {'key': 'dup_cms', 'name': '同键甲站', 'api': f'{base}/cms-dup1', 'type': 1, 'searchable': 1},
                {'key': 'dup_cms', 'name': '同键乙站', 'api': f'{base}/cms-dup2', 'type': 1, 'searchable': 1},
            ]
        },
        '/config-r2-parse': {
            'parses': [
                {'name': 'FailGlobal503', 'type': 1, 'url': f'{base}/r2-global-503?url='},
                {'name': 'ParseShowHD', 'type': 1, 'url': f'{base}/r2-parse-wrong?url=', 'ext': {'flag': ['高清']}},
                {'name': 'ParseFromB', 'type': 1, 'url': f'{base}/r2-parse-b?url=', 'ext': {'flag': ['B']}},
            ],
            'sites': [
                {
                    'key': 'r2_explicit',
                    'name': 'R2显式解析站',
                    'api': f'{base}/r2-cms-explicit',
                    'type': 1,
                    'parse': 1,
                    'playUrl': f'{base}/r2-site-parse?url=',
                    'searchable': 0,
                },
                {
                    'key': 'r2_override',
                    'name': 'R2手动覆盖站',
                    'api': f'{base}/r2-cms-override',
                    'type': 1,
                    'parse': 1,
                    'searchable': 0,
                },
                {
                    'key': 'r2_prefix',
                    'name': 'R2同源前缀头站',
                    'api': f'{base}/r2-cms-prefix',
                    'type': 1,
                    'playUrl': f'{base}/r2-prefix-ref?url=',
                    'header': {'Referer': 'https://r2-site.example/'},
                    'searchable': 0,
                },
                {
                    'key': 'r2_routing',
                    'name': 'R2结构化路由站',
                    'api': f'{base}/r2-cms-routing',
                    'type': 1,
                    'parse': 1,
                    'searchable': 0,
                },
                {
                    'key': 'r2_rel_query',
                    'name': 'R2相对嵌套解析站',
                    'api': f'{base}/r2-cms-r4',
                    'type': 1,
                    'parse': 1,
                    'playUrl': f'{base}/r2-rel-parse-entry?url=',
                    'searchable': 0,
                },
                {
                    'key': 'r2_xml_prefill',
                    'name': 'R2预带acXML站',
                    'api': f'{base}/r2-xml-prefill?lang=zh&ac=list',
                    'type': 0,
                    'searchable': 0,
                },
                {
                    'key': 'r2_html_login',
                    'name': 'R2登录页假成功站',
                    'api': f'{base}/r2-html-login',
                    'type': 1,
                    'searchable': 1,
                },
                {
                    'key': 'r2_xml_error',
                    'name': 'R2错误XML站',
                    'api': f'{base}/r2-xml-error',
                    'type': 0,
                    'searchable': 1,
                },
                {
                    'key': 'r2_rss_empty',
                    'name': 'R2合法空RSS站',
                    'api': f'{base}/r2-rss-empty',
                    'type': 0,
                    'searchable': 1,
                },
            ],
            'lives': [
                {
                    'group': 'R2代理节目单',
                    'channels': [
                        {
                            'name': '受保护Proxy节目单',
                            'header': {'Referer': 'https://r2-proxy-ref.example/'},
                            'urls': [
                                'proxy://do=live&type=txt&ext='
                                + base64.b64encode(f'{base}/r2-proxy-m3u'.encode('utf-8')).decode('ascii')
                            ],
                        }
                    ],
                }
            ],
        },
        '/config-r2-all-fail-search': {
            'sites': [
                {'key': 'r2_html_login', 'name': 'R2登录页站', 'api': f'{base}/r2-html-login', 'type': 1, 'searchable': 1},
                {'key': 'r2_xml_error', 'name': 'R2错误XML站', 'api': f'{base}/r2-xml-error', 'type': 0, 'searchable': 1},
            ]
        },
        '/config-r2-partial-fail-search': {
            'sites': [
                {'key': 'r2_html_login', 'name': 'R2登录页站', 'api': f'{base}/r2-html-login', 'type': 1, 'searchable': 1},
                {'key': 'r2_xml_error', 'name': 'R2错误XML站', 'api': f'{base}/r2-xml-error', 'type': 0, 'searchable': 1},
                {'key': 'r2_rss_empty', 'name': 'R2合法空RSS站', 'api': f'{base}/r2-rss-empty', 'type': 0, 'searchable': 1},
            ]
        },
        '/config-r2-pure-empty-rss': {
            'sites': [
                {'key': 'r2_rss_empty', 'name': 'R2合法空RSS站', 'api': f'{base}/r2-rss-empty', 'type': 0, 'searchable': 1},
            ]
        },
    }


FIXTURE_CONFIGS = build_fixture_configs()


def record_req(method: str, path: str, query: str, headers, status: int, extra: dict = None):
    if path in ('/_logs', '/_logs/clear'):
        return
    entry = {
        'ts': time.time(),
        'method': method,
        'path': path,
        'query': query,
        'referer': headers.get('Referer', ''),
        'userAgent': headers.get('User-Agent', ''),
        'status': status,
    }
    if extra:
        entry.update(extra)
    with REQUEST_LOG_LOCK:
        REQUEST_LOGS.append(entry)
        ALL_REQUEST_LOGS.append(entry)


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


class FixtureHandler(BaseHTTPRequestHandler):
    media_dir = ROOT / 'verification/private/lite'

    def _send_bytes(self, status: int, mime: str, data: bytes, extra_headers=None, log_extra=None):
        parsed = urlparse(self.path)
        size = len(data)
        start = 0
        end = size - 1
        partial = self.headers.get('Range', '')
        out_status = status
        payload = data
        if status == 200 and partial.startswith('bytes='):
            bounds = partial[6:].split('-', 1)
            start = int(bounds[0]) if bounds[0] else 0
            end = min(int(bounds[1]), end) if bounds[1] else end
            if start >= size:
                record_req(self.command, parsed.path, parsed.query, self.headers, 416, log_extra)
                self.send_error(416)
                return
            payload = data[start:end + 1]
            out_status = 206
        record_req(self.command, parsed.path, parsed.query, self.headers, out_status, log_extra)
        self.send_response(out_status)
        self.send_header('Content-Type', mime)
        self.send_header('Accept-Ranges', 'bytes')
        if out_status == 206:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def _send_json(self, status: int, obj, log_extra=None):
        data = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self._send_bytes(status, 'application/json; charset=utf-8', data, log_extra=log_extra)

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get('Content-Length', '0') or '0')
        body = self.rfile.read(length).decode('utf-8', errors='replace') if length > 0 else ''
        if parsed.path.startswith('/emby/'):
            self._send_json(200, {'ok': True, 'received': parsed.path}, log_extra={'bodyLen': len(body)})
            return
        self._send_json(404, {'error': 'not found'})

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parsed.query
        qs = parse_qs(query, keep_blank_values=True)
        base = 'http://10.0.2.2:8773'

        if path == '/_logs/clear':
            with REQUEST_LOG_LOCK:
                REQUEST_LOGS.clear()
            self._send_json(200, {'cleared': True})
            return
        if path == '/_logs':
            with REQUEST_LOG_LOCK:
                snap = list(REQUEST_LOGS)
            data = json.dumps(snap, ensure_ascii=False).encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return

        # Media files
        if path in ('/video.mp4', '/case15-a1.mp4'):
            self._send_bytes(200, 'video/mp4', (self.media_dir / 'baseline.mp4').read_bytes())
            return
        if path in ('/video2.mp4', '/case15-a2.mp4', '/case15-b1.mp4'):
            self._send_bytes(200, 'video/mp4', (self.media_dir / 'video2.mp4').read_bytes())
            return
        if path == '/short-live.mp4':
            self._send_bytes(200, 'video/mp4', (self.media_dir / 'short-live.mp4').read_bytes())
            return
        if path == '/stream.m3u8' or (path.startswith('/segment') and path.endswith('.ts') and path[8:-3].isdigit()):
            mime = 'application/vnd.apple.mpegurl' if path.endswith('.m3u8') else 'video/mp2t'
            self._send_bytes(200, mime, (self.media_dir / path[1:]).read_bytes())
            return
        if path.startswith('/hls-ref1/') or path.startswith('/hls-ref2/'):
            expected_ref = 'https://ref-line1.example/' if path.startswith('/hls-ref1/') else 'https://ref-line2.example/'
            got_ref = self.headers.get('Referer', '')
            if got_ref != expected_ref:
                self._send_bytes(403, 'text/plain; charset=utf-8', f'missing/wrong Referer: {got_ref}'.encode('utf-8'))
                return
            name = path.rsplit('/', 1)[1]
            if name == 'stream.m3u8' or (name.startswith('segment') and name.endswith('.ts')):
                mime = 'application/vnd.apple.mpegurl' if name.endswith('.m3u8') else 'video/mp2t'
                self._send_bytes(200, mime, (self.media_dir / name).read_bytes())
                return
        if path == '/parse-media.mp4':
            got_ref = self.headers.get('Referer', '')
            got_ua = self.headers.get('User-Agent', '')
            if got_ref != 'https://parse-ref.example/watch' or got_ua != 'ParsePlayer/1.0':
                self._send_bytes(403, 'text/plain; charset=utf-8', f'wrong headers ref={got_ref} ua={got_ua}'.encode('utf-8'))
                return
            self._send_bytes(200, 'video/mp4', (self.media_dir / 'baseline.mp4').read_bytes())
            return
        if path in ('/bad-fast.mp4', '/bad-all-1.mp4', '/bad-all-2.mp4', '/cms-fail'):
            self._send_bytes(500, 'text/plain; charset=utf-8', b'simulated failure')
            return
        if path == '/bad-hang.mp4':
            record_req(self.command, path, query, self.headers, 599, {'simulated': 'hang'})
            SERVER_STOP_EVENT.wait(35.0)
            try:
                self.send_response(504)
                self.send_header('Content-Length', '0')
                self.end_headers()
            except Exception:
                pass
            return

        # Redirected M3U live source
        if path == '/live-redir-entry.m3u':
            record_req(self.command, path, query, self.headers, 302)
            self.send_response(302)
            self.send_header('Location', f'{base}/live/sub/channels.m3u')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/live/sub/channels.m3u':
            m3u = (
                '#EXTM3U\n'
                '#EXTINF:-1 group-title="重定向相对组",双头相对台\n'
                '#EXTVLCOPT:http-referrer=https://ref-line1.example/\n'
                '../../hls-ref1/stream.m3u8\n'
                '#EXTINF:-1 group-title="重定向相对组",双头相对台\n'
                '#EXTVLCOPT:http-referrer=https://ref-line2.example/\n'
                '../../hls-ref2/stream.m3u8\n'
            )
            self._send_bytes(200, 'audio/x-mpegurl; charset=utf-8', m3u.encode('utf-8'))
            return

        # Config files
        if path in FIXTURE_CONFIGS:
            self._send_json(200, FIXTURE_CONFIGS[path])
            return
        if path == '/invalid':
            self._send_json(200, {})
            return

        # Baseline /cms
        if path == '/cms':
            self._send_json(
                200,
                {
                    'pagecount': 1,
                    'list': [
                        {
                            'vod_id': 'demo',
                            'vod_name': '合成测试',
                            'vod_content': '仅用于兼容验证',
                            'vod_play_from': '测试线路',
                            'vod_play_url': f'第一集${base}/video.mp4',
                        }
                    ],
                },
            )
            return

        # Site A (/cms-a): categories, pagination, multi-episode drama, auto-next drama, case 15 structured vod_play_list
        if path == '/cms-a':
            ac = qs.get('ac', [''])[0]
            ids = qs.get('ids', [''])[0]
            wd = qs.get('wd', [''])[0]
            pg = int(qs.get('pg', ['1'])[0] or '1')
            drama = {
                'vod_id': 'vod_drama',
                'vod_name': '测试连续剧',
                'vod_remarks': '共3集',
                'vod_content': '用于验证多集续播与全站搜索返回',
                'vod_play_from': '高清直链',
                'vod_play_url': f'第1集${base}/video.mp4#第2集${base}/video2.mp4#第3集${base}/video.mp4',
            }
            short_auto = {
                'vod_id': 'vod_short_auto',
                'vod_name': '自动连播回归剧',
                'vod_remarks': '2集',
                'vod_content': '第1集3秒后自动播第2集',
                'vod_play_from': '直链',
                'vod_play_url': f'第1集${base}/short-live.mp4#第2集${base}/video2.mp4',
            }
            case15 = {
                'vod_id': 'vod_case15',
                'vod_name': '结构化选集测试',
                'vod_remarks': '双线路',
                'vod_content': '验证 vod_play_list 双线路 2集+1集',
                'vod_play_list': [
                    {
                        'player_info': {'show': '蓝光直链', 'from': 'blueray'},
                        'urls': {
                            '1': {'name': '第1集', 'url': f'{base}/case15-a1.mp4'},
                            '2': {'name': '第2集', 'url': f'{base}/case15-a2.mp4'},
                        },
                    },
                    {
                        'player_info': {'show': '备用线路', 'from': 'backup'},
                        'url': f'正片${base}/case15-b1.mp4',
                    },
                ],
            }
            p2_first = {
                'vod_id': 'vod_p2_1',
                'vod_name': '分类二页首片',
                'vod_remarks': 'HD',
                'vod_play_from': '直链',
                'vod_play_url': f'正片${base}/video.mp4',
            }
            if ac == 'list':
                self._send_json(
                    200,
                    {
                        'code': 1,
                        'class': [
                            {'type_id': 'cat1', 'type_name': '动作'},
                            {'type_id': 'cat2', 'type_name': '科幻'},
                        ],
                        'pagecount': 2,
                        'list': [drama, case15],
                    },
                )
                return
            if ids == 'vod_drama':
                self._send_json(200, {'pagecount': 1, 'list': [drama]})
                return
            if ids == 'vod_short_auto':
                self._send_json(200, {'pagecount': 1, 'list': [short_auto]})
                return
            if ids == 'vod_case15':
                self._send_json(200, {'pagecount': 1, 'list': [case15]})
                return
            if ids == 'vod_p2_1':
                self._send_json(200, {'pagecount': 1, 'list': [p2_first]})
                return
            if wd:
                items = [drama] if ('共搜' in wd or '连续剧' in wd or '测试' in wd) else []
                self._send_json(200, {'pagecount': 1, 'list': items})
                return
            if pg == 2:
                self._send_json(200, {'pagecount': 2, 'list': [p2_first, drama]})
                return
            self._send_json(200, {'pagecount': 2, 'list': [drama, case15]})
            return

        # Site B (/cms-b)
        if path == '/cms-b':
            ids = qs.get('ids', [''])[0]
            wd = qs.get('wd', [''])[0]
            vod_b = {
                'vod_id': 'vod_b1',
                'vod_name': 'B站共搜影片',
                'vod_remarks': 'B站',
                'vod_content': '来自辅站B的搜索结果',
                'vod_play_from': 'B站直链',
                'vod_play_url': f'正片${base}/video2.mp4',
            }
            if ids == 'vod_b1':
                self._send_json(200, {'pagecount': 1, 'list': [vod_b]})
                return
            if wd:
                items = [vod_b] if '共搜' in wd else []
                self._send_json(200, {'pagecount': 1, 'list': items})
                return
            self._send_json(200, {'pagecount': 1, 'list': [vod_b]})
            return

        # Site Only-B (/cms-only-b)
        if path == '/cms-only-b':
            wd = qs.get('wd', [''])[0]
            vod_ob = {
                'vod_id': 'only_b_1',
                'vod_name': '新订阅B片',
                'vod_remarks': '仅B',
                'vod_play_from': '直链',
                'vod_play_url': f'正片${base}/video2.mp4',
            }
            if wd and '绝对零命中' in wd:
                self._send_json(200, {'pagecount': 1, 'list': []})
                return
            self._send_json(200, {'pagecount': 1, 'list': [vod_ob]})
            return

        # Strict MacCMS XML (/xml-strict): REJECTS ac=detail with HTTP 400!
        if path == '/xml-strict':
            ac = qs.get('ac', [''])[0]
            ids = qs.get('ids', [''])[0]
            wd = qs.get('wd', [''])[0]
            pg = qs.get('pg', ['1'])[0]
            if ac == 'detail':
                self._send_bytes(400, 'text/plain; charset=utf-8', b'strict XML rejects ac=detail')
                return
            if ac == 'list':
                xml = (
                    '<?xml version="1.0" encoding="utf-8"?><rss version="5.1">'
                    '<class><ty id="10">XML电影</ty><ty id="20">XML剧集</ty></class>'
                    '<list page="1" pagecount="2" pagesize="20" recordcount="2"/></rss>'
                )
                self._send_bytes(200, 'application/xml; charset=utf-8', xml.encode('utf-8'))
                return
            if ac == 'videolist':
                if wd and '共搜' in wd:
                    xml = '<?xml version="1.0" encoding="utf-8"?><rss version="5.1"><list page="1" pagecount="1"/></rss>'
                    self._send_bytes(200, 'application/xml; charset=utf-8', xml.encode('utf-8'))
                    return
                if wd and '绝对零命中' in wd:
                    xml = '<?xml version="1.0" encoding="utf-8"?><rss version="5.1"><list page="1" pagecount="1"/></rss>'
                    self._send_bytes(200, 'application/xml; charset=utf-8', xml.encode('utf-8'))
                    return
                if ids == 'xml_1':
                    xml = (
                        '<?xml version="1.0" encoding="utf-8"?><rss version="5.1">'
                        '<list page="1" pagecount="1"><video><id>xml_1</id>'
                        '<name><![CDATA[严格XML测试片]]></name><note><![CDATA[HD]]></note>'
                        f'<dl><dd flag="xml线"><![CDATA[正片${base}/video.mp4]]></dd></dl>'
                        '</video></list></rss>'
                    )
                    self._send_bytes(200, 'application/xml; charset=utf-8', xml.encode('utf-8'))
                    return
                xml = (
                    f'<?xml version="1.0" encoding="utf-8"?><rss version="5.1">'
                    f'<list page="{pg}" pagecount="2"><video><id>xml_1</id>'
                    '<name><![CDATA[严格XML测试片]]></name><note><![CDATA[HD]]></note></video></list></rss>'
                )
                self._send_bytes(200, 'application/xml; charset=utf-8', xml.encode('utf-8'))
                return
            self._send_bytes(400, 'text/plain; charset=utf-8', b'missing valid ac')
            return

        # JSON Parse CMS (/cms-parse, /cms-parse-empty) + Parse endpoints (/parse, /parse-empty)
        if path == '/cms-parse':
            wd = qs.get('wd', [''])[0]
            if wd:
                self._send_json(200, {'pagecount': 1, 'list': []})
                return
            vod_p = {
                'vod_id': 'vod_parse',
                'vod_name': 'JSON解析混线片',
                'vod_remarks': '解析+直链',
                'vod_play_from': 'JSON解析线$$$直链备线',
                'vod_play_url': (
                    '正片$https://origin.example/watch?a=1&b=hello%20world&c=x%26y'
                    f'$$$正片${base}/video2.mp4'
                ),
            }
            self._send_json(200, {'pagecount': 1, 'list': [vod_p]})
            return
        if path == '/cms-parse-empty':
            vod_pe = {
                'vod_id': 'vod_parse_empty',
                'vod_name': '空解析测试片',
                'vod_play_from': '空解析线',
                'vod_play_url': '正片$https://origin.example/empty',
            }
            self._send_json(200, {'pagecount': 1, 'list': [vod_pe]})
            return
        if path == '/parse':
            raw_param = ''
            for part in query.split('&'):
                if part.startswith('url='):
                    raw_param = unquote(part[4:])
            self._send_json(
                200,
                {
                    'code': 200,
                    'url': f'{base}/parse-media.mp4',
                    'header': {
                        'Referer': 'https://parse-ref.example/watch',
                        'User-Agent': 'ParsePlayer/1.0',
                    },
                },
                log_extra={'decodedUrlParam': raw_param},
            )
            return
        if path == '/parse-empty':
            self._send_json(200, {'code': 200, 'url': ''})
            return

        # Same siteKey + vodId, different siteApi (/cms-dup1, /cms-dup2)
        if path == '/cms-dup1':
            self._send_json(
                200,
                {
                    'pagecount': 1,
                    'list': [
                        {
                            'vod_id': '100',
                            'vod_name': '甲站电影',
                            'vod_remarks': '甲站',
                            'vod_play_from': '甲线',
                            'vod_play_url': f'第1集${base}/video.mp4',
                        }
                    ],
                },
            )
            return
        if path == '/cms-dup2':
            self._send_json(
                200,
                {
                    'pagecount': 1,
                    'list': [
                        {
                            'vod_id': '100',
                            'vod_name': '乙站剧集',
                            'vod_remarks': '乙站',
                            'vod_play_from': '乙线',
                            'vod_play_url': f'第1集${base}/video2.mp4',
                        }
                    ],
                },
            )
            return

        # === Round 2 (R2-R8) E2E Fixture Endpoints ===
        if path in ('/r2-ok-explicit.mp4', '/r2-ok-override.mp4', '/r2-ok-b.mp4'):
            self._send_bytes(200, 'video/mp4', (self.media_dir / 'baseline.mp4').read_bytes())
            return
        if path == '/r2-wrong.mp4':
            self._send_bytes(200, 'video/mp4', (self.media_dir / 'video2.mp4').read_bytes())
            return
        if path == '/r2-global-503':
            self._send_bytes(503, 'text/plain; charset=utf-8', b'global parser down')
            return
        if path == '/r2-site-parse':
            self._send_json(200, {'url': f'{base}/r2-ok-explicit.mp4'})
            return
        if path == '/r2-override-parse':
            self._send_json(200, {'url': f'{base}/r2-ok-override.mp4'})
            return
        if path == '/r2-parse-wrong':
            self._send_json(200, {'url': f'{base}/r2-wrong.mp4'})
            return
        if path == '/r2-parse-b':
            self._send_json(200, {'url': f'{base}/r2-ok-b.mp4'})
            return
        if path == '/r2-prefix-ref':
            got_ref = self.headers.get('Referer', '')
            if got_ref != 'https://r2-site.example/':
                self._send_bytes(403, 'text/plain; charset=utf-8', f'missing site Referer: {got_ref}'.encode('utf-8'))
                return
            self._send_bytes(200, 'video/mp4', (self.media_dir / 'baseline.mp4').read_bytes())
            return
        if path == '/r2-rel-parse-entry':
            record_req(self.command, path, query, self.headers, 302)
            self.send_response(302)
            self.send_header('Location', f'{base}/r2-v2/parsers/api')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/r2-v2/parsers/api':
            self._send_json(200, {'url': 'media/out.m3u8'})
            return
        if path == '/r2-v2/parsers/media/out.m3u8':
            self._send_bytes(200, 'application/vnd.apple.mpegurl', (self.media_dir / 'stream.m3u8').read_bytes())
            return
        if path.startswith('/r2-v2/parsers/media/segment') and path.endswith('.ts'):
            name = path.rsplit('/', 1)[1]
            self._send_bytes(200, 'video/mp2t', (self.media_dir / name).read_bytes())
            return
        if path == '/r2-cms-explicit':
            self._send_json(200, {
                'pagecount': 1,
                'list': [{
                    'vod_id': 'r2_exp_1',
                    'vod_name': 'R2显式解析片',
                    'vod_play_from': '高清',
                    'vod_play_url': f'正片${base}/watch-exp?id=1',
                }],
            })
            return
        if path == '/r2-cms-override':
            self._send_json(200, {
                'pagecount': 1,
                'list': [{
                    'vod_id': 'r2_ovr_1',
                    'vod_name': 'R2覆盖解析片',
                    'vod_play_from': '高清',
                    'vod_play_url': f'正片${base}/watch-ovr?id=2',
                }],
            })
            return
        if path == '/r2-cms-prefix':
            self._send_json(200, {
                'pagecount': 1,
                'list': [{
                    'vod_id': 'r2_pre_1',
                    'vod_name': 'R2前缀头片',
                    'vod_play_from': '前缀线',
                    'vod_play_url': f'正片${base}/watch-pre?id=3',
                }],
            })
            return
        if path == '/r2-cms-routing':
            self._send_json(200, {
                'pagecount': 1,
                'list': [{
                    'vod_id': 'r2_rt_1',
                    'vod_name': 'R2结构化路由片',
                    'vod_play_list': [
                        {
                            'player_info': {'show': '高清', 'from': 'B'},
                            'url': f'正片${base}/watch-rt?id=4',
                        }
                    ],
                }],
            })
            return
        if path == '/r2-cms-r4':
            self._send_json(200, {
                'pagecount': 1,
                'list': [{
                    'vod_id': 'r2_r4_1',
                    'vod_name': 'R4嵌套相对片',
                    'vod_play_from': '解析线',
                    'vod_play_url': f'正片${base}/watch-r4?next=https://cdn.invalid/fake.m3u8?ticket=demo',
                }],
            })
            return
        if path == '/r2-proxy-m3u':
            got_ref = self.headers.get('Referer', '')
            if got_ref != 'https://r2-proxy-ref.example/':
                self._send_bytes(403, 'text/plain; charset=utf-8', f'proxy m3u missing ref: {got_ref}'.encode('utf-8'))
                return
            m3u = (
                '#EXTM3U\n'
                '#EXTINF:-1 group-title="R2解码组",百分号编码台\n'
                f'{base}/r2-pct-hls/stream.m3u8|Referer=https%3A%2F%2Fr2-pct-tv.example%2F\n'
            )
            self._send_bytes(200, 'audio/x-mpegurl; charset=utf-8', m3u.encode('utf-8'))
            return
        if path.startswith('/r2-pct-hls/'):
            got_ref = self.headers.get('Referer', '')
            if got_ref != 'https://r2-pct-tv.example/':
                self._send_bytes(403, 'text/plain; charset=utf-8', f'pct hls wrong ref: {got_ref}'.encode('utf-8'))
                return
            name = path.rsplit('/', 1)[1]
            mime = 'application/vnd.apple.mpegurl' if name.endswith('.m3u8') else 'video/mp2t'
            self._send_bytes(200, mime, (self.media_dir / name).read_bytes())
            return
        if path == '/r2-xml-prefill':
            ac_list = qs.get('ac', [])
            lang_val = qs.get('lang', [''])[0]
            if len(ac_list) != 1 or lang_val != 'zh':
                self._send_bytes(400, 'text/plain; charset=utf-8', f'bad xml query: {query}'.encode('utf-8'))
                return
            if ac_list[0] == 'list':
                xml = '<?xml version="1.0" encoding="utf-8"?><rss><class><ty id="1">预带分类</ty></class><list page="1" pagecount="1"/></rss>'
                self._send_bytes(200, 'application/xml; charset=utf-8', xml.encode('utf-8'))
                return
            if ac_list[0] == 'videolist':
                xml = (
                    '<?xml version="1.0" encoding="utf-8"?><rss><list page="1" pagecount="1">'
                    '<video><id>r2_xml_1</id><name><![CDATA[预带XML片]]></name>'
                    f'<dl><dd flag="xml"><![CDATA[正片${base}/video.mp4]]></dd></dl></video></list></rss>'
                )
                self._send_bytes(200, 'application/xml; charset=utf-8', xml.encode('utf-8'))
                return
            self._send_bytes(400, 'text/plain; charset=utf-8', f'unsupported ac: {ac_list}'.encode('utf-8'))
            return
        if path == '/r2-html-login':
            self._send_bytes(200, 'text/html; charset=utf-8', b'<html><body>Login required</body></html>')
            return
        if path == '/r2-xml-error':
            self._send_bytes(200, 'application/xml; charset=utf-8', b'<error>upstream unavailable</error>')
            return
        if path == '/r2-rss-empty':
            self._send_bytes(200, 'application/xml; charset=utf-8', b'<?xml version="1.0" encoding="utf-8"?><rss><list page="1" pagecount="1"></list></rss>')
            return

        self._send_json(404, {'error': f'unknown path {path}'})

    def log_message(self, *a):
        pass


def build_probe_apk(build_dir: Path, candidate: bool):
    out = build_dir / 'probe'
    for d in ('classes', 'dex'):
        (out / d).mkdir(parents=True, exist_ok=True)
    for p in (out / 'classes').rglob('*.class'):
        p.unlink()
    for p in (out / 'dex').rglob('*.dex'):
        p.unlink()
    manifest = out / 'manifest.xml'
    manifest.write_text(
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
        f'package="{TEST_PACKAGE}">'
        '<uses-sdk android:minSdkVersion="14" android:targetSdkVersion="28"/>'
        '<application/>'
        f'<instrumentation android:name="com.pilipala.marcomovie.lite.LiteProbe" android:targetPackage="{PACKAGE}"/>'
        f'<instrumentation android:name="com.pilipala.marcomovie.lite.LiteUpgradeProbe" android:targetPackage="{PACKAGE}"/>'
        '</manifest>',
        encoding='utf-8',
    )
    assets = out / 'assets'
    assets.mkdir(exist_ok=True)
    if candidate:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID
        import datetime
        import ipaddress

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, '10.0.2.2')])
        now = datetime.datetime.now(datetime.timezone.utc)
        cert = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=2))
            .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
            .add_extension(
                x509.SubjectAlternativeName(
                    [x509.IPAddress(ipaddress.ip_address('10.0.2.2')), x509.DNSName('10.0.2.2')]
                ),
                critical=False,
            )
            .sign(key, hashes.SHA256())
        )
        (assets / 'test-ca.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        (out / 'test-key.pem').write_bytes(
            key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            )
        )
    run(exe(SDK, 'aapt2'), 'link', '-o', out / 'res.apk', '--manifest', manifest, '-I', API14, '-A', assets)
    run(
        exe(JDK / 'bin', 'javac'),
        '-encoding', 'UTF-8', '-source', '8', '-target', '8',
        '-bootclasspath', API14,
        '-classpath', build_dir / 'classes.jar',
        '-d', out / 'classes',
        ROOT / 'lite/tests/LiteProbe.java',
        ROOT / 'lite/tests/LiteUpgradeProbe.java',
    )
    with zipfile.ZipFile(out / 'classes.jar', 'w') as z:
        for p in (out / 'classes').rglob('*.class'):
            z.write(p, p.relative_to(out / 'classes').as_posix())
    run(
        exe(JDK / 'bin', 'java'),
        '-cp', SDK / 'lib/d8.jar',
        'com.android.tools.r8.D8',
        '--min-api', '14',
        '--lib', API14,
        '--classpath', build_dir / 'classes.jar',
        '--output', out / 'dex',
        out / 'classes.jar',
    )
    with zipfile.ZipFile(out / 'res.apk') as src, zipfile.ZipFile(out / 'unsigned.apk', 'w') as dst:
        for n in src.namelist():
            dst.writestr(n, src.read(n))
        dst.write(out / 'dex/classes.dex', 'classes.dex')
    run(exe(SDK, 'zipalign'), '-f', '4', out / 'unsigned.apk', out / 'aligned.apk')
    from android_build_common import resolve_signing_key
    key_path = resolve_signing_key(ROOT / 'lite', fallback_dirs=(ROOT / 'android-tv', ROOT / 'android-mobile'))
    run(
        exe(JDK / 'bin', 'java'),
        '-jar', SDK / 'lib/apksigner.jar',
        'sign', '--min-sdk-version', '14',
        '--ks', key_path,
        '--ks-key-alias', 'marcomovie',
        '--ks-pass', 'env:MARCOMOVIE_KEY_PASSWORD',
        '--out', out / 'probe.apk',
        out / 'aligned.apk',
    )
    return out


def main():
    parser = argparse.ArgumentParser(description='Run Marco Movie Lite API 14 emulator verification.')
    parser.add_argument('--apk', type=str, default='', help='Path to target Lite APK to install and test.')
    parser.add_argument('--candidate', action='store_true', help='Test candidate IJK/TLS build.')
    parser.add_argument('--serial', type=str, default='emulator-5580', help='API 14 emulator serial (emulator-*).')
    parser.add_argument('--baseline-only', action='store_true', help='Run only original 28 baseline API 14 checks.')
    parser.add_argument(
        '--upgrade-from-apk',
        type=str,
        default='',
        help='Optional official previous APK (e.g., 0.5.8) to seed data and verify in-place upgrade to --apk.',
    )
    parser.add_argument(
        '--evidence-dir',
        type=str,
        default=str(ROOT / 'verification/private/lite/evidence-059'),
        help='Directory to write verification logs and fixture snapshots.',
    )
    args = parser.parse_args()

    build_dir = ROOT / 'lite/build-candidate' if args.candidate else BUILD
    target_apk = Path(args.apk).resolve() if args.apk else default_apk_path(args.candidate).resolve()
    if not target_apk.exists():
        raise FileNotFoundError(f'Target Lite APK not found: {target_apk}')

    sdk_prop = adb_cmd(args.serial, 'shell', 'getprop', 'ro.build.version.sdk').strip()
    assert sdk_prop == '14', f'Expected API 14 emulator on {args.serial}, got SDK {sdk_prop}'

    evidence_dir = Path(args.evidence_dir).resolve()
    evidence_dir.mkdir(parents=True, exist_ok=True)
    fixtures_dir = evidence_dir / 'fixture-configs'
    fixtures_dir.mkdir(exist_ok=True)
    for route, cfg in FIXTURE_CONFIGS.items():
        (fixtures_dir / (route.lstrip('/') + '.json')).write_text(
            json.dumps(cfg, ensure_ascii=False, indent=2), encoding='utf-8'
        )

    FixtureHandler.media_dir = ensure_media_fixtures()
    out = build_probe_apk(build_dir, args.candidate)

    SERVER_STOP_EVENT.clear()
    with REQUEST_LOG_LOCK:
        REQUEST_LOGS.clear()
        ALL_REQUEST_LOGS.clear()

    server = ReusableThreadingHTTPServer(('127.0.0.1', 8773), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    secure = None
    if args.candidate:
        secure = ReusableThreadingHTTPServer(('127.0.0.1', 8774), FixtureHandler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.maximum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(out / 'assets/test-ca.pem', out / 'test-key.pem')
        secure.socket = ctx.wrap_socket(secure.socket, server_side=True)
        threading.Thread(target=secure.serve_forever, daemon=True).start()

    try:
        # Optional official 0.5.8 -> candidate 0.5.9 in-place upgrade verification
        if args.upgrade_from_apk:
            base_apk = Path(args.upgrade_from_apk).resolve()
            if not base_apk.exists():
                raise FileNotFoundError(f'Upgrade baseline APK not found: {base_apk}')
            print(f'=== Upgrade Check: {base_apk.name} -> {target_apk.name} ===')
            try:
                adb_cmd(args.serial, 'uninstall', PACKAGE)
            except Exception:
                pass
            print(adb_cmd(args.serial, 'install', '--no-streaming', str(base_apk)).strip())
            base_info = verify_installed_apk(args.serial, base_apk)
            print('Installed baseline APK verified:', json.dumps(base_info, ensure_ascii=False))
            print(adb_cmd(args.serial, 'install', '--no-streaming', '-r', str(out / 'probe.apk')).strip())

            seed_out = adb_cmd(
                args.serial, 'shell', 'am', 'instrument', '-w',
                f'{TEST_PACKAGE}/com.pilipala.marcomovie.lite.LiteUpgradeProbe',
                timeout=180,
            )
            (evidence_dir / 'upgrade-seed058.txt').write_text(seed_out, encoding='utf-8')
            print(seed_out.strip())
            assert 'PASS ' in seed_out and 'upgrade checks (seed058' in seed_out, (
                f'Official 0.5.8 seeding failed:\n{seed_out}'
            )

            # In-place upgrade WITHOUT uninstall or pm clear!
            print(adb_cmd(args.serial, 'install', '--no-streaming', '-r', str(target_apk)).strip())
            upgraded_info = verify_installed_apk(args.serial, target_apk)
            print('Upgraded candidate APK verified:', json.dumps(upgraded_info, ensure_ascii=False))

            verify_out = adb_cmd(
                args.serial, 'shell', 'am', 'instrument', '-w',
                '-e', 'mode', 'verify059',
                f'{TEST_PACKAGE}/com.pilipala.marcomovie.lite.LiteProbe',
                timeout=180,
            )
            (evidence_dir / 'upgrade-verify059.txt').write_text(verify_out, encoding='utf-8')
            print(verify_out.strip())
            assert 'PASS ' in verify_out and 'upgrade checks (verify059)' in verify_out, (
                f'Post-upgrade 0.5.9 verification failed:\n{verify_out}'
            )
            (evidence_dir / 'upgrade-verification.json').write_text(
                json.dumps(
                    {
                        'baseline_apk': base_info,
                        'upgraded_apk': upgraded_info,
                        'data_cleared': False,
                        'seed_passed': True,
                        'verify_passed': True,
                    },
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding='utf-8',
            )
        else:
            print(adb_cmd(args.serial, 'install', '--no-streaming', '-r', str(target_apk)).strip())
            print(adb_cmd(args.serial, 'install', '--no-streaming', '-r', str(out / 'probe.apk')).strip())

        installed_info = verify_installed_apk(args.serial, target_apk)
        (evidence_dir / 'installed-apk-verification.json').write_text(
            json.dumps(installed_info, ensure_ascii=False, indent=2), encoding='utf-8'
        )
        print('Verified installed target APK:', json.dumps(installed_info, ensure_ascii=False))

        # Run full API 14 device probe (baseline 28 checks + extended 0.5.9 E2E checks)
        extended_flag = 'false' if args.baseline_only else 'true'
        result = adb_cmd(
            args.serial, 'shell', 'am', 'instrument', '-w',
            '-e', 'candidate', str(args.candidate).lower(),
            '-e', 'extended', extended_flag,
            f'{TEST_PACKAGE}/com.pilipala.marcomovie.lite.LiteProbe',
            timeout=600,
        )
        (out / 'result.txt').write_text(result, encoding='utf-8')
        (evidence_dir / 'device-probe-result.txt').write_text(result, encoding='utf-8')
        print(result)
        expected_marker = 'PASS 33 API14 checks' if args.candidate else 'PASS 28 API14 checks'
        assert expected_marker in result, f'Missing {expected_marker} in:\n{result}'
        if not args.baseline_only:
            assert '0 FAILED, 0 SKIPPED' in result, f'Extended E2E checks failed:\n{result}'
    finally:
        SERVER_STOP_EVENT.set()
        with REQUEST_LOG_LOCK:
            lines = [json.dumps(item, ensure_ascii=False) for item in ALL_REQUEST_LOGS]
        (evidence_dir / 'server-requests.jsonl').write_text(
            '\n'.join(lines) + ('\n' if lines else ''), encoding='utf-8'
        )
        server.shutdown()
        server.server_close()
        if secure:
            secure.shutdown()
            secure.server_close()
        try:
            adb_cmd(args.serial, 'uninstall', TEST_PACKAGE)
        except Exception:
            pass


if __name__ == '__main__':
    main()
