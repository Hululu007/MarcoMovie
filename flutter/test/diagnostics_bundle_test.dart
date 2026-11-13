import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/app_log.dart';
import 'package:marco_movie/ui/apple_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Diagnostics bundle modal dialog renders bundle and copies to clipboard',
      (tester) async {
    const sampleBundle = 'MARCO MOVIE DIAGNOSTICS BUNDLE\nApp: Marco Movie\nTest error log';
    String? copiedText;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copiedText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => CupertinoButton(
            child: const Text('打开诊断日志'),
            onPressed: () {
              showAppleModalSheet<void>(
                context: context,
                title: '导出诊断日志包',
                builder: (ctx) => SingleChildScrollView(
                  child: Column(
                    children: [
                      const Text('诊断包已自动脱敏所有 Cookie、Token、密码及私有 URL 参数，可安全分享用于排查故障：'),
                      CupertinoTextField(
                        controller: TextEditingController(text: sampleBundle),
                        readOnly: true,
                      ),
                      CupertinoButton.filled(
                        onPressed: () {
                          Clipboard.setData(const ClipboardData(text: sampleBundle));
                          Navigator.of(ctx).pop();
                        },
                        child: const Text('复制诊断包内容到剪贴板'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开诊断日志'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('导出诊断日志包'), findsOneWidget);
    expect(
      find.text('诊断包已自动脱敏所有 Cookie、Token、密码及私有 URL 参数，可安全分享用于排查故障：'),
      findsOneWidget,
    );
    expect(find.text('复制诊断包内容到剪贴板'), findsOneWidget);

    await tester.tap(find.text('复制诊断包内容到剪贴板'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(copiedText, equals(sampleBundle));
  });
}
