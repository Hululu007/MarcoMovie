import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:marco_movie/core/app_update.dart';

void main() {
  test('mirror error falls back to the actual GitHub asset and normalizes preview tag', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.host != 'api.github.com') return http.Response('', 500);
      return http.Response(jsonEncode({'tag_name': 'v0.4.37-preview', 'assets': [{
        'name': 'MarcoMovie-0.4.37-windows-setup.exe', 'size': 20,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.4.37-preview/MarcoMovie-0.4.37-windows-setup.exe',
      }]}), 200);
    });
    final release = await AppUpdate.check(client: client, platform: 'windows');
    expect(calls, 2);
    expect(release.version, '0.4.37');
    expect(release.windowsUrl!.path, isNot(contains('preview-preview')));
  });
  test('failed checks never return current version as a successful result', () async {
    await expectLater(AppUpdate.check(client: MockClient((_) async => http.Response('', 503))),
        throwsA(isA<HttpException>()));
  });
  test('missing metadata and foreign host cannot enable an installer', () {
    final release = AppUpdate.parse({'versionName': '0.4.37', 'windows': {
      'url': 'https://unknown.example/MarcoMovie-0.4.37-windows-setup.exe',
      'sha256': 'a' * 64, 'size': 20,
    }});
    expect(release.windowsUrl, isNull);
    expect(AppUpdate.parse({'versionName': '0.4.37'}).windowsUrl, isNull);
  });
  test('same-length corruption and truncated installers fail verification', () async {
    final dir = await Directory.systemTemp.createTemp('marco-update-check-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/installer.exe');
    final good = utf8.encode('verified installer fixture');
    final release = AppUpdate('0.4.37', '', Uri.parse('https://github.com/Pilipala9919/MarcoMovie/releases/download/v0.4.37-preview/MarcoMovie-0.4.37-windows-setup.exe'), sha256.convert(good).toString(), good.length);
    await file.writeAsBytes(good);
    await release.verifyFile(file);
    await file.writeAsBytes(List.filled(good.length, 0));
    await expectLater(release.verifyFile(file), throwsFormatException);
    await file.writeAsBytes([1]);
    await expectLater(release.verifyFile(file), throwsFormatException);
  });

  test('platform releases do not upgrade other devices or choose a prerelease', () async {
    Map<String, dynamic> release(String platform, String version, String suffix,
        {bool prerelease = false}) => {
      'tag_name': '$platform-v$version', 'prerelease': prerelease,
      'assets': [{
        'name': 'MarcoMovie-$version-$suffix', 'size': 20,
        'digest': 'sha256:${'a' * 64}',
        'browser_download_url': 'https://github.com/Pilipala9919/MarcoMovie/releases/download/$platform-v$version/MarcoMovie-$version-$suffix',
      }],
    };
    final client = MockClient((request) async {
      if (request.url.host != 'api.github.com') return http.Response('', 404);
      return http.Response(jsonEncode([
        release('windows', '0.8.0', 'windows-setup.exe'),
        release('ios', '0.5.2', 'ios-unsigned.ipa', prerelease: true),
        release('ios', '0.5.1', 'ios-unsigned.ipa'),
        release('ios', '0.4.99', 'ios-unsigned.ipa'),
      ]), 200);
    });
    final ios = await AppUpdate.check(client: client, platform: 'ios');
    expect(ios.version, '0.5.1');
    expect(ios.windowsUrl, isNull);
    expect(ios.iosUrl, isNotNull);
    expect(
      ios.trollStoreInstallUrl.toString(),
      startsWith('apple-magnifier://install?url='),
    );
    final windows = await AppUpdate.check(client: client, platform: 'windows');
    expect(windows.version, '0.8.0');
    expect(windows.windowsUrl, isNotNull);
  });

  test('independent mirror feed wins without changing the legacy Android feed', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/movie/updates/ios.json');
      return http.Response(jsonEncode({
        'platform': 'ios', 'versionName': '0.5.1', 'notes': 'iPhone update',
        'package': {'url':'https://marcotv.wlj9919.top/movie/MarcoMovie-0.5.1-ios-unsigned.ipa',
          'size':100, 'sha256':'a' * 64},
        'signature': 'XOLvasep2jH9gRy01XjgQ4+iJcM/ccEM47iqnNIjD2IrIliO3/x0FQrTdOoFmuUdukksbNYabfCpMtPRahSoCQ==',
      }), 200);
    });
    final release = await AppUpdate.check(client: client, platform: 'ios');
    expect(release.version, '0.5.1');
    expect(release.windowsUrl, isNull);
    expect(() => AppUpdate.parse({'platform': 'ios', 'versionName': '0.5.1'}),
        throwsFormatException);
  });

  test('ReleaseNotesSummary condenses, deduplicates, categorizes and strips checksum clutter', () {
    const raw = '''
# Marco Movie Windows 0.5.18

发布日期：2026-11-12。应用版本：`0.5.18`（构建号 `68`）。本次更新升级沉浸式窗口与多线路兼容能力。

## 核心修复与优化

- **片源与网盘解析增强**：适配 32 款 WEX 插件并优化玩偶网盘分享解析（`ResilientHttpClient`）。
- **沉浸式窗口与中文安装向导**：Windows 标题栏升级沉浸式融合，安装程序全面切换简体中文。
- **修复更新后桌面重复图标**：覆盖升级不再重复创建桌面快捷方式。
- **片源与网盘解析增强**：适配 32 款 WEX 插件并优化玩偶网盘分享解析。

## 包信息与构建记录

- **安装版**：`MarcoMovie-0.5.18-windows-x64-setup.exe`，SHA-256：`aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`。
- **构建提交**：`0123456789abcdef`。

## 验证范围与已知限制

- 通过公共内容守卫检查与全部自动化测试。
- 已知限制：第三方上游站点受自身网络波动影响。
''';
    final summary = ReleaseNotesSummary.parse(raw);
    expect(summary.overview, contains('本次更新升级沉浸式窗口'));
    expect(summary.overview, isNot(contains('发布日期')));
    expect(summary.totalItems, 4);
    final titles = summary.sections.map((s) => s.title).toList();
    expect(titles, containsAll(['片源与播放', '界面与交互', '问题修复与优化', '注意事项']));
    final plain = summary.toPlainText();
    expect(plain, isNot(contains('SHA-256')));
    expect(plain, isNot(contains('公共内容守卫')));
  });
}
