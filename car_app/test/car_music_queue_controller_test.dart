import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/music_queue_models.dart';
import 'package:my_yaris/services/backend_client.dart';
import 'package:my_yaris/services/built_in_player_service.dart';
import 'package:my_yaris/services/car_music_queue_controller.dart';
import 'package:my_yaris/services/car_music_sync_service.dart';

class FakeBackendClient extends BackendClient {
  final Map<String, dynamic> Function(Uri uri, Map<String, String> queryParams)? onFetchQueue;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> body)? onPostIntelligence;
  final void Function(String commandId, String status, Map<String, dynamic> payload)? onAck;

  FakeBackendClient({
    this.onFetchQueue,
    this.onPostIntelligence,
    this.onAck,
  });

  @override
  Future<MusicQueueSnapshot> fetchMusicQueuePage({
    required String baseUrl,
    required String token,
    String? deviceId,
    String? source,
    int offset = 0,
    int limit = 50,
    String? queueId,
    int? queueVersion,
  }) async {
    if (onFetchQueue != null) {
      final queryParams = <String, String>{
        'offset': offset.toString(),
        'limit': limit.toString(),
      };
      if (deviceId != null) queryParams['device_id'] = deviceId;
      if (source != null) queryParams['source'] = source;
      if (queueId != null) queryParams['queue_id'] = queueId;
      if (queueVersion != null) queryParams['queue_version'] = queueVersion.toString();
      final uri = Uri.parse('$baseUrl/api/v1/music/queue').replace(queryParameters: queryParams);
      final json = onFetchQueue!(uri, queryParams);
      return MusicQueueSnapshot.fromJson(json);
    }
    throw BackendException(500, 'onFetchQueue not implemented');
  }

  @override
  Future<Map<String, dynamic>> requestIntelligenceBatch({
    required String baseUrl,
    required String token,
    required String requestId,
    required int seedSongId,
    required int playlistId,
    int batchIndex = 0,
    int count = 30,
  }) async {
    if (onPostIntelligence != null) {
      return onPostIntelligence!({
        'request_id': requestId,
        'seed_song_id': seedSongId,
        'playlist_id': playlistId,
        'batch_index': batchIndex,
        'count': count,
      });
    }
    throw BackendException(500, 'onPostIntelligence not implemented');
  }

  @override
  Future<bool> ackMusicCommand({
    required String baseUrl,
    required String token,
    required String commandId,
    required String status,
    String? appliedMode,
    int? queueVersion,
    int? currentIndex,
    String? currentTrackId,
    String? errorCode,
    String? errorDetail,
  }) async {
    if (onAck != null) {
      onAck!(commandId, status, {
        'applied_mode': appliedMode,
        'queue_version': queueVersion,
        'current_index': currentIndex,
        'current_track_id': currentTrackId,
        'error_code': errorCode,
        'error_detail': errorDetail,
      });
    }
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.ryanheise.just_audio.methods'), (call) async {
      return {};
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async {
      return null;
    });
  });

  group('V2.2 Queue Data Model & Validation Tests', () {
    test('Valid track item and snapshot parsing', () {
      final jsonTrack = {
        'track_id': 'netease_1901371647',
        'song_id': 1901371647,
        'title': '海阔天空',
        'artist': 'Beyond',
        'album': 'Words & Music Final Live',
        'duration_ms': 326000,
        'cover_url': 'https://example.com/cover.jpg',
        'stream_url': '/api/v1/music/netease/stream/1901371647',
        'fee': 0,
        'playable': null,
        'queue_index': 0,
      };

      final track = NeteaseQueueTrackItem.fromJson(jsonTrack);
      expect(track.trackId, 'netease_1901371647');
      expect(track.songId, 1901371647);
      expect(track.title, '海阔天空');
      expect(track.playable, isNull);

      final snapshotJson = {
        'code': 200,
        'queue_id': 'q_fav_a1b2c3d4e5f6',
        'queue_version': 102,
        'source': 'netease_favorite',
        'name': '我喜欢的音乐',
        'total': 1,
        'is_complete': true,
        'queue_state': 'ready',
        'offset': 0,
        'limit': 50,
        'has_more': false,
        'tracks': [jsonTrack],
      };

      final snapshot = MusicQueueSnapshot.fromJson(snapshotJson);
      expect(snapshot.queueId, 'q_fav_a1b2c3d4e5f6');
      expect(snapshot.total, 1);
      expect(snapshot.isComplete, true);
    });

    test('Strict song_id validation rejects missing or non-positive songId (prohibits songId 0 fallback)', () {
      final invalidJson = {
        'track_id': 'unknown_track',
        'title': 'Unknown',
        'stream_url': '/stream/unknown',
      };
      expect(() => NeteaseQueueTrackItem.fromJson(invalidJson), throwsFormatException);

      final zeroSongIdJson = {
        'song_id': 0,
        'title': 'Zero',
        'stream_url': '/stream/0',
      };
      expect(() => NeteaseQueueTrackItem.fromJson(zeroSongIdJson), throwsFormatException);
    });
  });

  group('CarMusicQueueController Buffered Multi-page & Atomic Apply Tests', () {
    late CarMusicQueueController queueCtrl;

    setUp(() {
      queueCtrl = CarMusicQueueController();
      queueCtrl.clear();
    });

    test('Multi-page continuous fetching buffers all pages and atomically applies only when complete', () async {
      // 120 total tracks across 3 pages: 50 + 50 + 20
      final fakeClient = FakeBackendClient(
        onFetchQueue: (uri, query) {
          final offset = int.parse(query['offset'] ?? '0');
          final limit = int.parse(query['limit'] ?? '50');
          const total = 120;

          final end = (offset + limit < total) ? offset + limit : total;
          final tracks = <Map<String, dynamic>>[];
          for (int i = offset; i < end; i++) {
            tracks.add({
              'track_id': 'netease_${1000 + i}',
              'song_id': 1000 + i,
              'title': 'Song $i',
              'artist': 'Artist',
              'stream_url': '/stream/${1000 + i}',
              'queue_index': i,
            });
          }

          return {
            'code': 200,
            'queue_id': 'q_fav_multipage_120',
            'queue_version': 77,
            'source': 'netease_favorite',
            'total': total,
            'is_complete': true,
            'queue_state': 'ready',
            'offset': offset,
            'limit': limit,
            'has_more': end < total,
            'tracks': tracks,
          };
        },
      );

      queueCtrl.configure(
        baseUrl: 'https://backend.example.ts.net',
        token: 'test-token',
        backendClient: fakeClient,
      );

      final success = await queueCtrl.loadFullFavoriteQueue();
      expect(success, true);
      expect(queueCtrl.isFullyLoaded, true);
      expect(queueCtrl.total, 120);
      expect(queueCtrl.tracks.length, 120);
      expect(queueCtrl.queueId, 'q_fav_multipage_120');
      expect(queueCtrl.queueVersion, 77);
      expect(queueCtrl.tracks[0].queueIndex, 0);
      expect(queueCtrl.tracks[119].queueIndex, 119);
    });

    test('409 QUEUE_VERSION_CONFLICT during paging discards dirty buffer and retries from offset 0', () async {
      int pageCallCount = 0;

      final fakeClient = FakeBackendClient(
        onFetchQueue: (uri, query) {
          pageCallCount++;
          final offset = int.parse(query['offset'] ?? '0');

          // First attempt page 0 succeeds with v1
          if (pageCallCount == 1) {
            return {
              'code': 200,
              'queue_id': 'q_conflict',
              'queue_version': 1,
              'source': 'netease_favorite',
              'total': 100,
              'is_complete': true,
              'queue_state': 'ready',
              'offset': 0,
              'limit': 50,
              'has_more': true,
              'tracks': List.generate(50, (i) => {
                'track_id': 'netease_$i',
                'song_id': 100 + i,
                'title': 'Song $i',
                'stream_url': '/$i',
                'queue_index': i,
              }),
            };
          }

          // First attempt page 1 fails with 409 (version shifted to v2)
          if (pageCallCount == 2) {
            throw BackendException(409, 'QUEUE_VERSION_CONFLICT');
          }

          // Retry attempt: succeeds with v2 (total=100)
          return {
            'code': 200,
            'queue_id': 'q_conflict',
            'queue_version': 2,
            'source': 'netease_favorite',
            'total': 50,
            'is_complete': true,
            'queue_state': 'ready',
            'offset': offset,
            'limit': 50,
            'has_more': false,
            'tracks': List.generate(50, (i) => {
              'track_id': 'netease_v2_$i',
              'song_id': 200 + i,
              'title': 'Song V2 $i',
              'stream_url': '/v2/$i',
              'queue_index': i,
            }),
          };
        },
      );

      queueCtrl.configure(
        baseUrl: 'https://backend.example.ts.net',
        token: 'test-token',
        backendClient: fakeClient,
      );

      final success = await queueCtrl.loadFullFavoriteQueue();
      expect(success, true);
      expect(queueCtrl.queueVersion, 2);
      expect(queueCtrl.tracks.first.trackId, 'netease_v2_0');
      expect(queueCtrl.isFullyLoaded, true);
    });

    test('Missing page / early has_more false preserves existing active queue without corruption', () async {
      // Set existing valid queue in controller
      queueCtrl.setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_original',
        queueVersion: 10,
        source: QueueSource.neteaseFavorite,
        total: 2,
        isComplete: true,
        offset: 0,
        limit: 2,
        hasMore: false,
        tracks: [
          const NeteaseQueueTrackItem(
            trackId: 'netease_orig_1',
            songId: 111,
            title: 'Orig 1',
            artist: 'Orig',
            streamUrl: '/orig/1',
            queueIndex: 0,
          ),
          const NeteaseQueueTrackItem(
            trackId: 'netease_orig_2',
            songId: 222,
            title: 'Orig 2',
            artist: 'Orig',
            streamUrl: '/orig/2',
            queueIndex: 1,
          ),
        ],
      ));

      // Client returns incomplete queue: total=100, but only 10 tracks returned and has_more=false
      final fakeClient = FakeBackendClient(
        onFetchQueue: (uri, query) => {
          'code': 200,
          'queue_id': 'q_broken',
          'queue_version': 1,
          'source': 'netease_favorite',
          'total': 100,
          'is_complete': true,
          'queue_state': 'ready',
          'offset': 0,
          'limit': 50,
          'has_more': false,
          'tracks': List.generate(10, (i) => {
            'track_id': 'netease_broken_$i',
            'song_id': 300 + i,
            'title': 'Broken $i',
            'stream_url': '/$i',
            'queue_index': i,
          }),
        },
      );

      queueCtrl.configure(
        baseUrl: 'https://backend.example.ts.net',
        token: 'test-token',
        backendClient: fakeClient,
      );

      final success = await queueCtrl.loadFullFavoriteQueue(maxRetries: 1);
      expect(success, false);

      // Verify original queue is completely preserved!
      expect(queueCtrl.queueId, 'q_original');
      expect(queueCtrl.queueVersion, 10);
      expect(queueCtrl.tracks.length, 2);
      expect(queueCtrl.tracks.first.trackId, 'netease_orig_1');
    });

    test('Duplicate track_id encountered in pages preserves existing queue', () async {
      queueCtrl.setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_valid_stay',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 1,
        isComplete: true,
        offset: 0,
        limit: 1,
        hasMore: false,
        tracks: [
          const NeteaseQueueTrackItem(
            trackId: 'netease_stay',
            songId: 999,
            title: 'Stay',
            artist: 'Stay',
            streamUrl: '/stay',
            queueIndex: 0,
          ),
        ],
      ));

      final fakeClient = FakeBackendClient(
        onFetchQueue: (uri, query) => {
          'code': 200,
          'queue_id': 'q_duplicate',
          'queue_version': 1,
          'source': 'netease_favorite',
          'total': 2,
          'is_complete': true,
          'queue_state': 'ready',
          'offset': 0,
          'limit': 50,
          'has_more': false,
          'tracks': [
            {
              'track_id': 'netease_dup_1',
              'song_id': 500,
              'title': 'Dup 1',
              'stream_url': '/1',
              'queue_index': 0,
            },
            {
              'track_id': 'netease_dup_1', // Duplicate track_id!
              'song_id': 500,
              'title': 'Dup 1 duplicate',
              'stream_url': '/1',
              'queue_index': 1,
            },
          ],
        },
      );

      queueCtrl.configure(
        baseUrl: 'https://backend.example.ts.net',
        token: 'test-token',
        backendClient: fakeClient,
      );

      final success = await queueCtrl.loadFullFavoriteQueue(maxRetries: 1);
      expect(success, false);
      expect(queueCtrl.queueId, 'q_valid_stay');
      expect(queueCtrl.tracks.first.trackId, 'netease_stay');
    });
  });

  group('CarMusicQueueController Modes & Circuit Breaker Tests', () {
    late CarMusicQueueController queueCtrl;

    setUp(() {
      queueCtrl = CarMusicQueueController();
      queueCtrl.clear();
    });

    test('list_loop mode sequential traversal and cyclic wrap', () {
      final tracks = List.generate(
        4,
        (i) => NeteaseQueueTrackItem(
          trackId: 'netease_${10 + i}',
          songId: 10 + i,
          title: 'Track $i',
          artist: 'Artist $i',
          streamUrl: '/stream/${10 + i}',
          queueIndex: i,
        ),
      );

      queueCtrl.setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_list_test',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 4,
        isComplete: true,
        offset: 0,
        limit: 4,
        hasMore: false,
        tracks: tracks,
      ));

      queueCtrl.setPlaybackMode(PlaybackMode.listLoop);
      expect(queueCtrl.currentIndex, 0);

      expect(queueCtrl.getNextTrack()?.trackId, 'netease_11');
      expect(queueCtrl.getNextTrack()?.trackId, 'netease_12');
      expect(queueCtrl.getNextTrack()?.trackId, 'netease_13');
      expect(queueCtrl.getNextTrack()?.trackId, 'netease_10'); // Wraps to 0
    });

    test('shuffle activation gate and Fisher-Yates permutation', () {
      // Incomplete queue: shuffle fails
      queueCtrl.setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_inc',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 5,
        isComplete: false,
        offset: 0,
        limit: 1,
        hasMore: true,
        tracks: [
          const NeteaseQueueTrackItem(
            trackId: 'netease_1',
            songId: 1,
            title: 'T1',
            artist: 'A1',
            streamUrl: '/1',
            queueIndex: 0,
          ),
        ],
      ));

      expect(queueCtrl.setPlaybackMode(PlaybackMode.shuffle), false);

      // Complete queue: shuffle succeeds with seed at 0
      final fullTracks = List.generate(
        5,
        (i) => NeteaseQueueTrackItem(
          trackId: 'netease_${50 + i}',
          songId: 50 + i,
          title: 'T$i',
          artist: 'A$i',
          streamUrl: '/$i',
          queueIndex: i,
        ),
      );

      queueCtrl.setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_complete',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 5,
        isComplete: true,
        offset: 0,
        limit: 5,
        hasMore: false,
        tracks: fullTracks,
      ), startIndex: 2);

      expect(queueCtrl.setPlaybackMode(PlaybackMode.shuffle), true);
      expect(queueCtrl.shuffleIndices.length, 5);
      expect(queueCtrl.shuffleIndices[0], 2); // Current track seed
    });

    test('single_track completion stops player (returns null)', () {
      queueCtrl.switchQueue(
        source: QueueSource.singleTrack,
        singleTrackItem: const NeteaseQueueTrackItem(
          trackId: 'netease_single_1',
          songId: 777,
          title: 'Single',
          artist: 'Artist',
          streamUrl: '/single',
          queueIndex: 0,
        ),
      );

      expect(queueCtrl.queueSource, QueueSource.singleTrack);
      expect(queueCtrl.getNextTrack(), isNull); // Stop on end
    });

    test('Circuit breaker halts at 3 consecutive failures with PLAYBACK_CONSECUTIVE_FAILURES', () {
      expect(queueCtrl.recordPlaybackFailure('403'), CircuitBreakerAction.skipToNext);
      expect(queueCtrl.recordPlaybackFailure('Decode error'), CircuitBreakerAction.skipToNext);
      expect(queueCtrl.recordPlaybackFailure('Timeout'), CircuitBreakerAction.stopPlayer);
      expect(queueCtrl.consecutiveFailures, 3);
      expect(queueCtrl.errorCode, 'PLAYBACK_CONSECUTIVE_FAILURES');

      queueCtrl.recordPlaybackSuccess();
      expect(queueCtrl.consecutiveFailures, 0);
      expect(queueCtrl.errorCode, isNull);
    });
  });

  group('CarMusicSyncService End-to-End Fake Protocol & Pending Snapshot Tests', () {
    late CarMusicSyncService syncService;

    setUp(() {
      syncService = CarMusicSyncService();
      CarMusicQueueController().clear();
    });

    test('set_playback_mode with prepared queue_id and version awaits atomic load and reports ACK', () async {
      String? ackCommandId;
      String? ackStatus;
      String? ackAppliedMode;
      int? ackQueueVersion;

      final fakeClient = FakeBackendClient(
        onFetchQueue: (uri, query) => {
          'code': 200,
          'queue_id': 'q_intel_prepared_001',
          'queue_version': 1,
          'source': 'netease_intelligence',
          'total': 1,
          'is_complete': true,
          'queue_state': 'ready',
          'offset': 0,
          'limit': 50,
          'has_more': false,
          'tracks': [
            {
              'track_id': 'netease_8888',
              'song_id': 8888,
              'title': 'Intel Song',
              'artist': 'Intel Artist',
              'stream_url': '/stream/8888',
              'queue_index': 0,
            },
          ],
        },
        onAck: (cmdId, status, payload) {
          ackCommandId = cmdId;
          ackStatus = status;
          ackAppliedMode = payload['applied_mode'] as String?;
          ackQueueVersion = payload['queue_version'] as int?;
        },
      );

      syncService.start(
        baseUrl: 'https://backend.example.ts.net',
        deviceId: 'car_test',
        token: 'test-token',
        backendClient: fakeClient,
      );

      await syncService.handleCommand({
        'command_id': 'cmd_intel_001',
        'action': 'set_playback_mode',
        'params': {
          'mode': 'intelligence',
          'queue_id': 'q_intel_prepared_001',
          'queue_version': 1,
        },
      });

      expect(ackCommandId, 'cmd_intel_001');
      expect(ackStatus, 'applied');
      expect(ackAppliedMode, 'intelligence');
      expect(ackQueueVersion, 1);
      expect(CarMusicQueueController().queueId, 'q_intel_prepared_001');
      expect(CarMusicQueueController().appliedMode, PlaybackMode.intelligence);
    });

    test('set_playback_mode error reports failed ACK and preserves existing playback state', () async {
      String? ackStatus;
      String? ackErrorCode;

      final fakeClient = FakeBackendClient(
        onFetchQueue: (uri, query) {
          throw BackendException(502, 'INTELLIGENCE_UPSTREAM_FAILED');
        },
        onAck: (cmdId, status, payload) {
          ackStatus = status;
          ackErrorCode = payload['error_code'] as String?;
        },
      );

      syncService.start(
        baseUrl: 'https://backend.example.ts.net',
        deviceId: 'car_test',
        token: 'test-token',
        backendClient: fakeClient,
      );

      await syncService.handleCommand({
        'command_id': 'cmd_failed_001',
        'action': 'set_playback_mode',
        'params': {
          'mode': 'intelligence',
          'queue_id': 'q_intel_broken',
          'queue_version': 1,
        },
      });

      expect(ackStatus, 'failed');
      expect(ackErrorCode, 'COMMAND_EXECUTION_ERROR');
      // Applied mode must remain untouched (listLoop)
      expect(CarMusicQueueController().appliedMode, PlaybackMode.listLoop);
    });

    test('Mode switch preserves paused state (Zero Auto-Play)', () async {
      // Ensure player is stopped/paused
      await BuiltInPlayerService().stop();
      expect(BuiltInPlayerService().player.playing, false);

      CarMusicQueueController().setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_fav_stay_paused',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 2,
        isComplete: true,
        offset: 0,
        limit: 2,
        hasMore: false,
        tracks: [
          const NeteaseQueueTrackItem(
            trackId: 'netease_p1',
            songId: 101,
            title: 'P1',
            artist: 'A1',
            streamUrl: '/p1',
            queueIndex: 0,
          ),
          const NeteaseQueueTrackItem(
            trackId: 'netease_p2',
            songId: 102,
            title: 'P2',
            artist: 'A2',
            streamUrl: '/p2',
            queueIndex: 1,
          ),
        ],
      ));

      await syncService.handleCommand({
        'command_id': 'cmd_stay_paused',
        'action': 'set_playback_mode',
        'params': {'mode': 'single_loop'},
      });

      // Player must remain paused/stopped (did not auto play!)
      expect(BuiltInPlayerService().player.playing, false);
      expect(CarMusicQueueController().appliedMode, PlaybackMode.singleLoop);
    });

    test('play_track with unknown track not in queue fails without fabricating fake singleItem', () async {
      String? ackStatus;

      final fakeClient = FakeBackendClient(
        onAck: (cmdId, status, payload) {
          ackStatus = status;
        },
      );

      syncService.start(
        baseUrl: 'https://backend.example.ts.net',
        deviceId: 'car_test',
        token: 'test-token',
        backendClient: fakeClient,
      );

      // Active queue has only track netease_555
      CarMusicQueueController().setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_only_555',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 1,
        isComplete: true,
        offset: 0,
        limit: 1,
        hasMore: false,
        tracks: [
          const NeteaseQueueTrackItem(
            trackId: 'netease_555',
            songId: 555,
            title: 'Song 555',
            artist: 'A',
            streamUrl: '/555',
            queueIndex: 0,
          ),
        ],
      ));

      // Attempt to play unknown track without server queue_id
      await syncService.handleCommand({
        'command_id': 'cmd_play_unknown',
        'action': 'play_track',
        'params': {'track_id': 'netease_999999'},
      });

      expect(ackStatus, 'failed');
      expect(CarMusicQueueController().queueId, 'q_only_555'); // Queue was not corrupted with fake singleItem!
    });

    test('HTTP/WS command deduplication and expiration protection', () async {
      await BuiltInPlayerService().setVolume(0.20);

      // 1. Expired command is dropped
      final expiredTime = DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String();
      await syncService.handleCommand({
        'command_id': 'cmd_exp',
        'action': 'set_volume',
        'expires_at': expiredTime,
        'params': {'volume': 0.05},
      });
      expect(BuiltInPlayerService().currentVolume, 0.20);

      // 2. Command executes first time
      await syncService.handleCommand({
        'command_id': 'cmd_dedup',
        'action': 'set_volume',
        'params': {'volume': 0.12},
      });
      expect(BuiltInPlayerService().currentVolume, 0.12);

      // Manually set to 0.30
      await BuiltInPlayerService().setVolume(0.30);

      // Duplicate invocation of cmd_dedup is dropped without re-executing
      await syncService.handleCommand({
        'command_id': 'cmd_dedup',
        'action': 'set_volume',
        'params': {'volume': 0.12},
      });
      expect(BuiltInPlayerService().currentVolume, 0.30);
    });
  });
}
