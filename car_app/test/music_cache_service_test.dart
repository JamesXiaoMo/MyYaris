import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/music_queue_models.dart';
import 'package:my_yaris/services/music_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('MusicCacheService SD Card Cache Tests', () {
    late Directory tmpDir;
    late HttpServer server;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('myyaris_cache_test_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (req.uri.path == '/audio/valid') {
          // Valid ID3 MP3 header + 16KB payload
          final bytes = List<int>.filled(16384, 0xAA);
          bytes[0] = 0x49; // 'I'
          bytes[1] = 0x44; // 'D'
          bytes[2] = 0x33; // '3'
          req.response.statusCode = 200;
          req.response.add(bytes);
          await req.response.close();
        } else if (req.uri.path == '/audio/bad') {
          // Non-audio HTML error body
          req.response.statusCode = 200;
          req.response.write('<html>not audio</html>' * 600);
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
      await MusicCacheService().init(overrideDir: tmpDir);
    });

    tearDown(() async {
      MusicCacheService().wifiCheckerOverride = null;
      await server.close(force: true);
      if (await tmpDir.exists()) {
        await tmpDir.delete(recursive: true);
      }
    });

    test('Atomic download saves valid audio and rejects invalid header', () async {
      final svc = MusicCacheService();
      final base = 'http://127.0.0.1:${server.port}';

      final ok = await svc.downloadTrack(
        songId: 1001,
        fullStreamUrl: '$base/audio/valid',
        token: 't',
      );
      expect(ok, isTrue);
      expect(svc.getCachedFile(1001), isNotNull);
      expect(svc.cachedCountNotifier.value, 1);

      final bad = await svc.downloadTrack(
        songId: 1002,
        fullStreamUrl: '$base/audio/bad',
        token: 't',
      );
      expect(bad, isFalse);
      expect(svc.getCachedFile(1002), isNull);
    });

    test('Batch cache enforces Wi-Fi gate and skips already cached tracks', () async {
      final svc = MusicCacheService();
      final base = 'http://127.0.0.1:${server.port}';
      final tracks = [
        NeteaseQueueTrackItem(
          trackId: 'netease_2001',
          songId: 2001,
          queueIndex: 0,
          title: 'Song A',
          artist: 'Artist',
          durationMs: 180000,
          streamUrl: '/audio/valid',
          playable: true,
        ),
        NeteaseQueueTrackItem(
          trackId: 'netease_2002',
          songId: 2002,
          queueIndex: 1,
          title: 'Song B',
          artist: 'Artist',
          durationMs: 180000,
          streamUrl: '/audio/valid',
          playable: true,
        ),
      ];

      // 1. Blocked when not on Wi-Fi
      svc.wifiCheckerOverride = () async => false;
      await svc.startBatchCacheFavorites(
        baseUrl: base,
        token: 't',
        deviceId: 'car_p3pro',
        overrideTracks: tracks,
      );
      expect(svc.batchProgressNotifier.value.state, BatchCacheState.error);
      expect(svc.getCachedFile(2001), isNull);

      // 2. Allowed on Wi-Fi
      svc.wifiCheckerOverride = () async => true;
      await svc.startBatchCacheFavorites(
        baseUrl: base,
        token: 't',
        deviceId: 'car_p3pro',
        overrideTracks: tracks,
      );
      expect(svc.batchProgressNotifier.value.state, BatchCacheState.completed);
      expect(svc.batchProgressNotifier.value.done, 2);
      expect(svc.getCachedFile(2001), isNotNull);
      expect(svc.getCachedFile(2002), isNotNull);

      // 3. Second run skips both
      await svc.startBatchCacheFavorites(
        baseUrl: base,
        token: 't',
        deviceId: 'car_p3pro',
        overrideTracks: tracks,
      );
      expect(svc.batchProgressNotifier.value.skipped, 2);

      // 4. Clear removes files
      await svc.clearAllCache();
      expect(svc.getCachedFile(2001), isNull);
      expect(svc.cachedCountNotifier.value, 0);
    });
  });
}
