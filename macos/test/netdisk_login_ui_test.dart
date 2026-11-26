import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:marco_movie/core/netdisk_service.dart';
import 'package:marco_movie/core/quark_account.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:marco_movie/ui/local_qr_code.dart';
import 'package:marco_movie/ui/netdisk_sheet.dart';

class PendingLogin extends NetdiskService {
  final creations = <Completer<NetdiskQrSession>>[];
  final polls = <Completer<NetdiskPollResult>>[];
  String Function(String driveKey, String raw)? onVerifyWebAuth;
  @override
  Future<NetdiskQrSession> createQrSession(String driveKey) {
    final result = Completer<NetdiskQrSession>();
    creations.add(result);
    return result.future;
  }

  @override
  Future<NetdiskPollResult> pollQrStatus(NetdiskQrSession session) {
    final result = Completer<NetdiskPollResult>();
    polls.add(result);
    return result.future;
  }

  @override
  Future<String> verifyWebAuthCredential(
    String driveKey,
    String rawCredential,
  ) async {
    if (onVerifyWebAuth != null) {
      return onVerifyWebAuth!(driveKey, rawCredential);
    }
    return super.verifyWebAuthCredential(driveKey, rawCredential);
  }
}

NetdiskQrSession challenge(String token, {String driveKey = 'quark'}) => NetdiskQrSession(
  driveKey: driveKey,
  qrContentUrl: 'https://login.example/confirm?token=$token',
  qrImageUrl: '',
  token: token,
);
String credential() => QuarkAccountSession(
  cookie: '__pus=fixture-identity; __puus=fixture-cookie',
  driveSt: 'fixture-drive-ticket',
  accountId: sha256.convert(utf8.encode('fixture-identity')).toString(),
  validatedAt: DateTime.now(),
).toCredential();

Future<StorageService> open(WidgetTester tester, PendingLogin service,
    {String driveKey = 'quark', VoidCallback? onChanged}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(service.close);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showNetdiskAccountSheet(
              context,
              storage,
              initialDriveKey: driveKey,
              onChanged: onChanged,
              service: service,
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return storage;
}

void main() {
  testWidgets('Baidu confirmed without account verification is not saved as login',
      (tester) async {
    final service = PendingLogin();
    var changes = 0;
    final storage = await open(tester, service,
        driveKey: 'baidu', onChanged: () => changes++);
    service.creations.single.complete(challenge('baidu-incomplete', driveKey: 'baidu'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    service.polls.single.complete(const NetdiskPollResult(
        state: NetdiskPollState.confirmed, message: 'Confirmed',
        credential: 'BDUSS=fixture-incomplete-account'));
    await tester.pump();
    await tester.pump();
    expect(storage.getNetdiskCred('baidu'), isEmpty);
    expect(storage.isNetdiskLoggedIn('baidu'), isFalse);
    expect(changes, 0);
    expect(find.byType(LocalQrCode), findsOneWidget);
    expect(find.text('账户验证未完成，请刷新二维码重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Baidu scanned authorization resumes and persists the complete session',
      (tester) async {
    final service = PendingLogin();
    var changes = 0;
    final storage = await open(tester, service,
        driveKey: 'baidu', onChanged: () => changes++);
    service.creations.single.complete(challenge('baidu-login', driveKey: 'baidu'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    service.polls.single.complete(const NetdiskPollResult(
        state: NetdiskPollState.scanned, message: '已扫码，正在完成百度授权'));
    await tester.pump();
    await tester.pump();
    expect(storage.isNetdiskLoggedIn('baidu'), isFalse);
    expect(find.text('已扫码，正在完成百度授权'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 6));
    expect(service.polls, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.polls, hasLength(2));
    const account = 'BDUSS=fixture-baidu-account; STOKEN=fixture-baidu-session';
    service.polls.last.complete(const NetdiskPollResult(
        state: NetdiskPollState.confirmed, message: '百度扫码登录成功',
        credential: account, accountVerified: true));
    await tester.pump();
    await tester.pump();
    expect(storage.isNetdiskLoggedIn('baidu'), isTrue);
    expect((await StorageService.init()).getNetdiskCred('baidu'), account);
    expect(storage.isNetdiskLoggedIn('quark'), isFalse);
    expect(changes, 1);
    expect(find.byType(LocalQrCode), findsNothing);
    expect(find.descendant(
        of: find.byKey(const ValueKey('netdisk-scan-btn-baidu')),
        matching: find.text('重新扫码')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(service.polls, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'refresh replaces the real local QR and rejects an older creation',
    (tester) async {
      final service = PendingLogin();
      final storage = await open(tester, service);
      await tester.ensureVisible(find.text('刷新二维码'));
      await tester.tap(find.text('刷新二维码'));
      await tester.pump();
      expect(service.creations.length, 2);
      service.creations[1].complete(challenge('new'));
      await tester.pump();
      service.creations[0].complete(challenge('old'));
      await tester.pump();
      expect(
        tester.widget<LocalQrCode>(find.byType(LocalQrCode)).data,
        contains('token=new'),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('我已扫码授权'), findsNothing);
      expect(storage.isNetdiskLoggedIn('quark'), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'late poll after refresh cannot save credentials and polls never overlap',
    (tester) async {
      final service = PendingLogin();
      final storage = await open(tester, service);
      service.creations.single.complete(challenge('first'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 9));
      expect(service.polls.length, 1);
      await tester.ensureVisible(find.text('刷新二维码'));
      await tester.tap(find.text('刷新二维码'));
      await tester.pump();
      service.polls.single.complete(
        NetdiskPollResult(
          state: NetdiskPollState.confirmed,
          message: 'Authenticated',
          credential: credential(),
        ),
      );
      await tester.pump();
      expect(storage.getNetdiskCred('quark'), isEmpty);
      service.creations.last.complete(challenge('second'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      service.polls.last.complete(
        NetdiskPollResult(
          state: NetdiskPollState.confirmed,
          message: 'Authenticated',
          credential: credential(),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(storage.isNetdiskLoggedIn('quark'), isTrue);
      expect(find.byKey(const ValueKey('quark-browse-files')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing login ignores an in-flight successful response', (
    tester,
  ) async {
    final service = PendingLogin();
    final storage = await open(tester, service);
    service.creations.single.complete(challenge('closed'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byIcon(CupertinoIcons.xmark_circle_fill));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    service.polls.single.complete(
      NetdiskPollResult(
        state: NetdiskPollState.confirmed,
        message: 'Authenticated',
        credential: credential(),
      ),
    );
    await tester.pump();
    expect(storage.getNetdiskCred('quark'), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'legacy placeholders are not authenticated and external changes invalidate shared sessions',
    () async {
      SharedPreferences.setMockInitialValues({
        StorageService.keyQuarkCookie: '__puus=qr_auth_old',
      });
      final storage = await StorageService.init();
      final second = await StorageService.init();
      expect(storage.isNetdiskLoggedIn('quark'), isFalse);
      expect(identical(storage.quarkAccounts, second.quarkAccounts), isTrue);
      final generation = storage.quarkAccounts.generation;
      await storage.setNetdiskCred('quark', credential());
      expect(storage.isNetdiskLoggedIn('quark'), isTrue);
      expect(storage.quarkAccounts.generation, greaterThan(generation));
      await second.setNetdiskCred('quark', '');
      expect(storage.isNetdiskLoggedIn('quark'), isFalse);
    },
  );

  testWidgets('a late waiting response stays paused until one foreground poll', (tester) async {
    final service = PendingLogin();
    await open(tester, service);
    service.creations.single.complete(challenge('background-wait'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(service.polls.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.polls.single.complete(NetdiskPollResult(
      state: NetdiskPollState.waiting, message: 'Waiting'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(service.polls.length, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.polls.length, 2);
    await tester.pump(const Duration(seconds: 10));
    expect(service.polls.length, 2, reason: 'Resuming does not overlap polls.');
    service.polls.last.complete(NetdiskPollResult(
      state: NetdiskPollState.waiting, message: 'Waiting'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an in-flight confirmed login is saved while background polling stops', (tester) async {
    final service = PendingLogin();
    final storage = await open(tester, service);
    service.creations.single.complete(challenge('background-success'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.polls.single.complete(NetdiskPollResult(
      state: NetdiskPollState.confirmed, message: 'Authenticated', credential: credential()));
    await tester.pump();
    await tester.pump();
    expect(storage.isNetdiskLoggedIn('quark'), isTrue);
    await tester.pump(const Duration(seconds: 10));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.polls.length, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('QR creation finishing in background does not begin polling', (tester) async {
    final service = PendingLogin();
    await open(tester, service);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.creations.single.complete(challenge('background-create'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(service.polls, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.polls.length, 1);
    await tester.pumpWidget(const SizedBox());
    service.polls.single.complete(NetdiskPollResult(
      state: NetdiskPollState.waiting, message: 'Waiting'));
    await tester.pump();
  });

  test('all 4 netdisk drives expose valid phone/tablet deep links and web auth URLs', () {
    final quarkPhone = NetdiskService.buildNativeAppDeepLinks(
      'quark',
      'https://su.quark.cn/4_eMHBJ?token=qtoken123',
    );
    final quarkPad = NetdiskService.buildNativeAppDeepLinks(
      'quark',
      'https://su.quark.cn/4_eMHBJ?token=qtoken123',
      isTablet: true,
    );
    expect(quarkPhone.first, startsWith('qklink://www.uc.cn/656bdcddd4758b39206a8181c91a7d14?'));
    expect(quarkPad.first, startsWith('qklink://www.uc.cn/e7d506280d7f0140e2ee4ba5b030d82d?'));
    expect(quarkPhone.last, startsWith('qkcloudlink://www.uc.cn/ca7b1fad21e741b3a4aa4284ce58d686?'));

    final ucPhone = NetdiskService.buildNativeAppDeepLinks(
      'uc',
      'https://su.uc.cn/1_n0ZCv?token=utoken456',
    );
    final ucPad = NetdiskService.buildNativeAppDeepLinks(
      'uc',
      'https://su.uc.cn/1_n0ZCv?token=utoken456',
      isTablet: true,
    );
    expect(ucPhone.first, startsWith('uclink://www.uc.cn/f11f7cb5d16fa0969d670c1eccc6053d?'));
    expect(ucPad.first, startsWith('uclink://www.uc.cn/3898f2889dfc4651a3726ffbc5d1e198?'));
    expect(ucPhone.last, startsWith('ucliteioslink://www.uc.cn/8c09be3332aa631fcbad0c5834ef68fd?'));

    final baiduLinks = NetdiskService.buildNativeAppDeepLinks(
      'baidu',
      'https://wappass.baidu.com/wp/?qrlogin&sign=abc',
    );
    expect(baiduLinks.single, startsWith('baiduboxapp://easybrowse?openurl='));
    expect(
      NetdiskService.buildNativeWebAuthUrl('baidu'),
      contains('wappass.baidu.com/passport/?login&tpl=netdisk'),
    );
    expect(
      NetdiskService.buildNativeWebAuthUrl('ali'),
      contains('auth.aliyundrive.com/v2/oauth/authorize?client_id=25dzX3vbYqktVxyX'),
    );
  });

  testWidgets('Baidu and Aliyun same-device jump saves verified credentials and keeps polling on cancel',
      (tester) async {
    final calls = <MethodCall>[];
    Map<String, dynamic>? nextResult;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(netdiskAuthChannel, (call) async {
      calls.add(call);
      return nextResult;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(netdiskAuthChannel, null);
    });

    // 1. Baidu: first cancel modal (polling must stay alive), then confirm via App jump
    final baiduService = PendingLogin()
      ..onVerifyWebAuth = (driveKey, raw) {
        expect(driveKey, 'baidu');
        return raw;
      };
    var baiduChanges = 0;
    final storage = await open(
      tester,
      baiduService,
      driveKey: 'baidu',
      onChanged: () => baiduChanges++,
    );
    baiduService.creations.single.complete(challenge('baidu-jump', driveKey: 'baidu'));
    await tester.pump();

    nextResult = null; // User dismisses modal without authorizing yet
    await tester.ensureVisible(find.byKey(const ValueKey('netdisk-jump-baidu')));
    await tester.tap(find.byKey(const ValueKey('netdisk-jump-baidu')));
    await tester.pump();
    expect(calls.last.method, 'startWebAuth');
    expect((calls.last.arguments as Map)['drive'], 'baidu');
    await tester.pump(const Duration(milliseconds: 200));
    expect(baiduService.polls, hasLength(1),
        reason: 'Cancelling same-device modal must re-arm QR polling');
    baiduService.polls.single.complete(
      const NetdiskPollResult(state: NetdiskPollState.waiting, message: 'Waiting'),
    );
    await tester.pump();

    nextResult = <String, dynamic>{
      'type': 'credential',
      'credential': 'BDUSS=jump-bduss; STOKEN=jump-stoken',
    };
    await tester.tap(find.byKey(const ValueKey('netdisk-jump-baidu')));
    await tester.pump();
    await tester.pump();
    expect(storage.isNetdiskLoggedIn('baidu'), isTrue);
    expect(storage.getNetdiskCred('baidu'), 'BDUSS=jump-bduss; STOKEN=jump-stoken');
    expect(baiduChanges, 1);
    expect(find.byType(LocalQrCode), findsNothing);
    await tester.pumpWidget(const SizedBox());

    // 2. Aliyun: GBK bizExt returned from native mobile OAuth modal
    final aliService = PendingLogin();
    var aliChanges = 0;
    final aliStorage = await open(
      tester,
      aliService,
      driveKey: 'ali',
      onChanged: () => aliChanges++,
    );
    aliService.creations.single.complete(challenge('ali-jump', driveKey: 'ali'));
    await tester.pump();
    expect(find.byKey(const ValueKey('netdisk-ali-scan-app')), findsOneWidget);

    final gbkBizExt = base64Encode([
      ...utf8.encode('{"pds_login_result":{"nickName":"'),
      0xB2, 0x5C, // GBK '餐' with 0x5C trail byte
      ...utf8.encode('","refreshToken":"ali-mobile-jump-token-123456"}}'),
    ]);
    nextResult = <String, dynamic>{'type': 'bizExt', 'bizExt': gbkBizExt};
    await tester.ensureVisible(find.byKey(const ValueKey('netdisk-jump-ali')));
    await tester.tap(find.byKey(const ValueKey('netdisk-jump-ali')));
    await tester.pump();
    await tester.pump();
    expect(aliStorage.isNetdiskLoggedIn('ali'), isTrue);
    expect(aliStorage.getNetdiskCred('ali'), 'ali_token=ali-mobile-jump-token-123456');
    expect(aliChanges, 1);
    expect(find.byType(LocalQrCode), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
