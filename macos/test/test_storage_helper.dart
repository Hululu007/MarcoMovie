import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/core/secure_credential_store.dart';
import 'package:marco_movie/core/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Initializes a [StorageService] backed by in-memory file and credential stores
/// for deterministic `FakeAsync` / `testWidgets` execution without disk I/O.
Future<StorageService> initTestStorage({
  Map<String, Object> initialPrefs = const <String, Object>{},
  StorageFileStore? fileStore,
  SecureCredentialStore? secureStore,
  Pbkdf2ComputeRunner? pbkdf2Runner,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final storage = await StorageService.init(
    fileStore: fileStore,
    secureStore: secureStore,
    pbkdf2Runner: pbkdf2Runner ?? <T>(computation) => Future<T>.sync(computation),
  );
  addTearDown(() {
    storage.cancelPendingHistoryFlush();
    storage.cancelPendingAutoSync();
  });
  return storage;
}
