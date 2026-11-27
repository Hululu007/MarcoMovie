import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;
import 'package:flutter/foundation.dart';
import 'storage_service.dart';

class LogEntry {
  final DateTime timestamp;
  final String level;
  final String source;
  final String message;
  final String? stackTrace;
  final String? context;
  final String? library;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.source,
    required this.message,
    this.stackTrace,
    this.context,
    this.library,
  });

  String toFormattedLine() {
    final sb = StringBuffer()
      ..write('${timestamp.toUtc().toIso8601String()} [$level] [$source] $message');
    if (context != null && context!.isNotEmpty) {
      sb.write('\n  Context: $context');
    }
    if (library != null && library!.isNotEmpty) {
      sb.write('\n  Library: $library');
    }
    if (stackTrace != null && stackTrace!.isNotEmpty) {
      sb.write('\n  Stack Trace:\n$stackTrace');
    }
    return sb.toString();
  }
}

class AppLog {
  static AppLog? _instance;
  static AppLog get instance => _instance ??= AppLog();

  static const int maxTotalBytes = 1024 * 1024; // 1 MB total bounded
  static const int maxFileBytes = 512 * 1024; // 512 KB per rotating file

  Directory? _logDirectory;
  final ListQueue<LogEntry> _inMemoryBuffer = ListQueue<LogEntry>();
  int _inMemoryBytes = 0;
  static bool _hooksInstalled = false;

  AppLog({Directory? logDirectory}) : _logDirectory = logDirectory;

  static void init({Directory? logDirectory}) {
    final logger = instance;
    if (logDirectory != null) {
      logger._logDirectory = logDirectory;
    }
    _installHooks();
  }

  void setLogDirectory(Directory logDirectory) {
    _logDirectory = logDirectory;
  }

  Directory? get logDirectory => _logDirectory;

  static void _installHooks() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;

    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      instance.logError(
        details.exceptionAsString(),
        source: 'FlutterError',
        stackTrace: details.stack?.toString(),
        context: details.context?.toString(),
        library: details.library,
      );
      originalOnError?.call(details);
    };

    final originalPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      instance.logError(
        error.toString(),
        source: 'PlatformDispatcher',
        stackTrace: stack.toString(),
      );
      if (originalPlatformError != null) {
        return originalPlatformError(error, stack);
      }
      return false;
    };
  }

  // 6-pass automatic redaction regex patterns:
  // 1. Authorization headers (Bearer, Basic, etc.)
  static final RegExp _bearerBasicAuthRegex = RegExp(
    r'(authorization\s*:\s*(?:bearer|basic)?\s*)([^\r\n]+)',
    caseSensitive: false,
  );

  // 2. Cookie / Set-Cookie headers
  static final RegExp _cookieHeaderRegex = RegExp(
    r'(set-cookie\s*:\s*|cookie\s*:\s*)([^\r\n]+)',
    caseSensitive: false,
  );

  // 3. Embedded URL credentials (e.g. https://user:password@host)
  static final RegExp _urlCredentialsRegex = RegExp(
    r'(https?://[^:\s/@]+:)([^@\s/]+)(@)',
    caseSensitive: false,
  );

  // 4. Sensitive URL query parameters
  static final RegExp _urlQueryParamRegex = RegExp(
    r'''([\?&](?:token|accesstoken|access_token|refreshtoken|refresh_token|authtoken|auth_token|auth|sign|signature|sig|password|pwd|passwd|passcode|key|apikey|api_key|appkey|secret|secret_key|ticket|session|session_id|hash|code|pin)=)([^&\s#'">]+)''',
    caseSensitive: false,
  );

  // 5. JSON credential keys
  static final RegExp _jsonSensitiveKeysRegex = RegExp(
    r'("(?:password|passwd|pwd|passcode|secret|api_key|apikey|appkey|private_key|privatekey|pin|access_token|accesstoken|refresh_token|refreshtoken|auth_token|authtoken|token|cookie)"\s*:\s*)"([^"]*)"',
    caseSensitive: false,
  );

  // 6. Key-value credential pairs (e.g. password: ... or password=...)
  static final RegExp _kvSensitiveRegex = RegExp(
    r'''((?:password|passwd|pwd|passcode|secret|api_key|apikey|pin|access_token|accesstoken|token)\s*[:=]\s*)(?!\[REDACTED\])([^\s,;&'"\r\n]+)''',
    caseSensitive: false,
  );

  /// 6-pass automatic redaction for credentials, tokens, cookies, and sensitive URL query strings.
  static String redact(String input) {
    if (input.isEmpty) return input;
    var result = input;
    result = result.replaceAllMapped(_bearerBasicAuthRegex, (m) => '${m[1]}[REDACTED]');
    result = result.replaceAllMapped(_cookieHeaderRegex, (m) => '${m[1]}[REDACTED]');
    result = result.replaceAllMapped(_urlCredentialsRegex, (m) => '${m[1]}[REDACTED]${m[3]}');
    result = result.replaceAllMapped(_urlQueryParamRegex, (m) => '${m[1]}[REDACTED]');
    result = result.replaceAllMapped(_jsonSensitiveKeysRegex, (m) => '${m[1]}"[REDACTED]"');
    result = result.replaceAllMapped(_kvSensitiveRegex, (m) => '${m[1]}[REDACTED]');
    return result;
  }

  File? get _activeLogFile =>
      _logDirectory == null ? null : File('${_logDirectory!.path}/error.log');
  File? get _oldLogFile =>
      _logDirectory == null ? null : File('${_logDirectory!.path}/error.log.old');

  void logError(
    String message, {
    String source = 'App',
    String? stackTrace,
    String? context,
    String? library,
  }) {
    final redactedMsg = redact(message);
    final redactedStack = stackTrace != null ? redact(stackTrace) : null;
    final redactedContext = context != null ? redact(context) : null;

    final entry = LogEntry(
      timestamp: DateTime.now().toUtc(),
      level: 'ERROR',
      source: source,
      message: redactedMsg,
      stackTrace: redactedStack,
      context: redactedContext,
      library: library,
    );

    final line = '${entry.toFormattedLine()}\n';
    final lineBytes = utf8.encode(line).length;

    // Layer 1: In-memory circular buffer capped at 1MB
    _inMemoryBuffer.addLast(entry);
    _inMemoryBytes += lineBytes;
    while (_inMemoryBytes > maxTotalBytes && _inMemoryBuffer.isNotEmpty) {
      final removed = _inMemoryBuffer.removeFirst();
      _inMemoryBytes -= utf8.encode('${removed.toFormattedLine()}\n').length;
    }

    // Layer 2: File-backed dual-file rotating logs capped at 1MB total (512KB each)
    if (_logDirectory != null) {
      try {
        if (!_logDirectory!.existsSync()) {
          _logDirectory!.createSync(recursive: true);
        }
        final active = _activeLogFile!;
        if (active.existsSync() && active.lengthSync() >= maxFileBytes) {
          final old = _oldLogFile!;
          if (old.existsSync()) {
            old.deleteSync();
          }
          active.renameSync(old.path);
        }
        active.writeAsStringSync(line, mode: FileMode.append, flush: true);
      } catch (e) {
        debugPrint('AppLog file write error: $e');
      }
    }
  }

  Future<String> exportLogsFormatted() async {
    if (_logDirectory != null) {
      final sb = StringBuffer();
      final old = _oldLogFile;
      if (old != null && await old.exists()) {
        try {
          sb.write(await old.readAsString());
        } catch (_) {}
      }
      final active = _activeLogFile;
      if (active != null && await active.exists()) {
        try {
          sb.write(await active.readAsString());
        } catch (_) {}
      }
      final fileContent = sb.toString();
      if (fileContent.isNotEmpty) return fileContent;
    }
    return _inMemoryBuffer.map((e) => e.toFormattedLine()).join('\n');
  }

  static Future<String> generateDiagnosticsBundle({
    required StorageService storage,
    required String currentAppVersion,
    String? platformOverride,
    String? osVersionOverride,
    String? localeOverride,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final platform = platformOverride ?? Platform.operatingSystem;
    final osVersion = osVersionOverride ?? Platform.operatingSystemVersion;
    final locale = localeOverride ?? Platform.localeName;
    final subs = storage.getSubscriptions();
    final subsCount = subs.length;
    final isWebdav = storage.isWebdavConfigured;
    final ambient = storage.ambientGlowEnabled;
    final blur = storage.glassBlurLevel;

    final logs = await instance.exportLogsFormatted();

    final buffer = StringBuffer();
    buffer.writeln('================================================================================');
    buffer.writeln('MARCO MOVIE DIAGNOSTICS BUNDLE (AUTOMATICALLY REDACTED)');
    buffer.writeln('Generated: $now');
    buffer.writeln('================================================================================\n');

    buffer.writeln('[SYSTEM & ENVIRONMENT]');
    buffer.writeln('App: Marco Movie v$currentAppVersion');
    buffer.writeln('Platform: $platform ($osVersion)');
    buffer.writeln('Locale: $locale');
    buffer.writeln('Subscriptions Count: $subsCount');
    buffer.writeln('WebDAV Configured: $isWebdav');
    buffer.writeln('Ambient Glow: $ambient');
    buffer.writeln('Glass Blur Level: $blur\n');

    buffer.writeln('[RECENT ERROR LOGS (MAX 1MB CIRCULAR BUFFER)]');
    if (logs.trim().isEmpty) {
      buffer.writeln('(No errors recorded)');
    } else {
      buffer.writeln(logs.trim());
    }
    buffer.writeln('\n================================================================================');
    buffer.writeln('END OF DIAGNOSTICS BUNDLE');
    buffer.writeln('================================================================================');
    return buffer.toString();
  }

  @visibleForTesting
  void clear() {
    _inMemoryBuffer.clear();
    _inMemoryBytes = 0;
    try {
      if (_activeLogFile?.existsSync() == true) _activeLogFile!.deleteSync();
      if (_oldLogFile?.existsSync() == true) _oldLogFile!.deleteSync();
    } catch (_) {}
  }
}
