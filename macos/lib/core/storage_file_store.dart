import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Injectable file storage abstraction for [StorageService].
///
/// Production uses [DiskStorageFileStore] backed by real files on disk;
/// tests default to [InMemoryStorageFileStore] so `testWidgets` (`FakeAsync`)
/// never blocks on native `dart:io` asynchronous file operations.
abstract class StorageFileStore {
  Future<void> ensureInitialized();

  bool existsSync(String fileName);

  Future<bool> exists(String fileName);

  List<int> readBytesSync(String fileName);

  void writeBytesSync(String fileName, List<int> bytes);

  Future<void> writeStringAndFlush(String fileName, String content);

  Future<void> rename(String fromFileName, String toFileName);

  Future<void> deleteFile(String fileName);

  List<String> listFileNamesSync();
}

/// Production [StorageFileStore] backed by a real [Directory] on disk.
class DiskStorageFileStore implements StorageFileStore {
  final Directory directory;

  DiskStorageFileStore(this.directory);

  File _file(String fileName) => File('${directory.path}/$fileName');

  @override
  Future<void> ensureInitialized() async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }

  @override
  bool existsSync(String fileName) => _file(fileName).existsSync();

  @override
  Future<bool> exists(String fileName) => _file(fileName).exists();

  @override
  List<int> readBytesSync(String fileName) => _file(fileName).readAsBytesSync();

  @override
  void writeBytesSync(String fileName, List<int> bytes) {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    _file(fileName).writeAsBytesSync(bytes, flush: true);
  }

  @override
  Future<void> writeStringAndFlush(String fileName, String content) async {
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = _file(fileName);
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.write);
      await raf.writeString(content);
      await raf.flush();
      await raf.close();
      raf = null;
    } finally {
      if (raf != null) {
        try {
          await raf.close();
        } on Object catch (e) {
          debugPrint('DiskStorageFileStore: close failed for $fileName: $e');
        }
      }
    }
  }

  @override
  Future<void> rename(String fromFileName, String toFileName) async {
    await _file(fromFileName).rename(_file(toFileName).path);
  }

  @override
  Future<void> deleteFile(String fileName) async {
    final f = _file(fileName);
    if (await f.exists()) {
      await f.delete();
    }
  }

  @override
  List<String> listFileNamesSync() {
    if (!directory.existsSync()) return const <String>[];
    return directory
        .listSync(followLinks: false)
        .whereType<File>()
        .map((f) => f.uri.pathSegments.isNotEmpty
            ? f.uri.pathSegments.last
            : f.path.split(RegExp(r'[\\/]')).last)
        .toList(growable: false);
  }
}

/// Pure in-memory [StorageFileStore] for fast, deterministic `FakeAsync` tests.
class InMemoryStorageFileStore implements StorageFileStore {
  final Map<String, Uint8List> _files = <String, Uint8List>{};

  InMemoryStorageFileStore([Map<String, List<int>>? initialFiles]) {
    if (initialFiles != null) {
      for (final entry in initialFiles.entries) {
        _files[entry.key] = Uint8List.fromList(entry.value);
      }
    }
  }

  @override
  Future<void> ensureInitialized() => Future<void>.value();

  @override
  bool existsSync(String fileName) => _files.containsKey(fileName);

  @override
  Future<bool> exists(String fileName) =>
      Future<bool>.value(_files.containsKey(fileName));

  @override
  List<int> readBytesSync(String fileName) {
    final bytes = _files[fileName];
    if (bytes == null) {
      throw FileSystemException('File not found', fileName);
    }
    return Uint8List.fromList(bytes);
  }

  @override
  void writeBytesSync(String fileName, List<int> bytes) {
    _files[fileName] = Uint8List.fromList(bytes);
  }

  void writeStringSync(String fileName, String content) {
    _files[fileName] = Uint8List.fromList(utf8.encode(content));
  }

  String? readStringOrNull(String fileName) {
    final bytes = _files[fileName];
    if (bytes == null) return null;
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<void> writeStringAndFlush(String fileName, String content) {
    _files[fileName] = Uint8List.fromList(utf8.encode(content));
    return Future<void>.value();
  }

  @override
  Future<void> rename(String fromFileName, String toFileName) {
    final data = _files.remove(fromFileName);
    if (data == null) {
      throw FileSystemException('Source file not found', fromFileName);
    }
    _files[toFileName] = data;
    return Future<void>.value();
  }

  @override
  Future<void> deleteFile(String fileName) {
    _files.remove(fileName);
    return Future<void>.value();
  }

  @override
  List<String> listFileNamesSync() => _files.keys.toList(growable: false);
}
