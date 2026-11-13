import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:marco_movie/ui/poster_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LruMap unit tests', () {
    test('enforces capacity limit and evicts least recently inserted', () {
      final lru = LruMap<int, String>(3);
      lru[1] = 'one';
      lru[2] = 'two';
      lru[3] = 'three';
      expect(lru.length, 3);
      expect(lru.containsKey(1), isTrue);

      // Inserting 4th item evicts 1
      lru[4] = 'four';
      expect(lru.length, 3);
      expect(lru.containsKey(1), isFalse);
      expect(lru[2], 'two');
      expect(lru[3], 'three');
      expect(lru[4], 'four');
    });

    test('promotes accessed items on read', () {
      final lru = LruMap<int, String>(3);
      lru[1] = 'one';
      lru[2] = 'two';
      lru[3] = 'three';

      // Read key 1 -> 1 becomes MRU
      expect(lru[1], 'one');

      // Now insert 4 -> key 2 should be evicted (LRU), not key 1
      lru[4] = 'four';
      expect(lru.length, 3);
      expect(lru.containsKey(2), isFalse);
      expect(lru.containsKey(1), isTrue);
      expect(lru.containsKey(3), isTrue);
      expect(lru.containsKey(4), isTrue);
    });

    test('replaces existing key without changing size', () {
      final lru = LruMap<String, int>(2);
      lru['a'] = 1;
      lru['b'] = 2;
      // Overwriting 'a' makes 'a' MRU and 'b' LRU
      lru['a'] = 10;
      expect(lru.length, 2);

      // Inserting 'c' should evict 'b' since 'a' was updated recently
      lru['c'] = 3;
      expect(lru.containsKey('b'), isFalse);
      expect(lru.containsKey('a'), isTrue);
      expect(lru['a'], 10);
      expect(lru['c'], 3);
    });

    test('handles 500-entry capacity correctly', () {
      final lru = LruMap<int, int>(500);
      for (int i = 0; i < 550; i++) {
        lru[i] = i * 2;
      }
      expect(lru.length, 500);
      // Items 0..49 should be evicted
      for (int i = 0; i < 50; i++) {
        expect(lru.containsKey(i), isFalse);
      }
      // Items 50..549 should exist
      for (int i = 50; i < 550; i++) {
        expect(lru[i], i * 2);
      }
    });

    test('clear removes all entries', () {
      final lru = LruMap<int, String>(5);
      lru[1] = 'a';
      lru[2] = 'b';
      lru.clear();
      expect(lru.length, 0);
      expect(lru.isEmpty, isTrue);
      expect(lru[1], isNull);
    });
  });

  group('PosterLoader Dimension and LRU Integration', () {
    test('isClearPosterBytes returns false for undersized payload', () async {
      final small = Uint8List(100);
      expect(await PosterLoader.isClearPosterBytes(small), isFalse);
    });

    test('isTrueHdPoster returns false for undersized payload', () async {
      final small = Uint8List(100);
      expect(await PosterLoader.isTrueHdPoster(small), isFalse);
    });

    test('isClearPosterBytes handles corrupted image with graceful fallback', () async {
      // 20KB corrupted data
      final corrupt = Uint8List(20 * 1024);
      final isClear = await PosterLoader.isClearPosterBytes(corrupt);
      // Fallback: bytes.length >= 42 * 1024 -> false for 20KB
      expect(isClear, isFalse);

      // 50KB corrupted data -> fallback >= 42KB -> true
      final corrupt50k = Uint8List(50 * 1024);
      final isClear50k = await PosterLoader.isClearPosterBytes(corrupt50k);
      expect(isClear50k, isTrue);
    });

    test('clearCache resets all caches cleanly', () async {
      await PosterLoader.clearCache();
      expect(PosterLoader.peekMemory('https://site.example/test.jpg'), isNull);
    });
  });
}
