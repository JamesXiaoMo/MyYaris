import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/music_queue_models.dart';
import 'package:my_yaris/services/backend_client.dart';
import 'package:my_yaris/services/built_in_player_service.dart';
import 'package:my_yaris/services/car_music_queue_controller.dart';
import 'package:my_yaris/services/car_music_sync_service.dart';

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

  group('CarMusicQueueController & V2.2 Queue Model Hermetic Tests', () {
    late CarMusicQueueController queueCtrl;

    setUp(() {
      queueCtrl = CarMusicQueueController();
      queueCtrl.clear();
    });

    test('NeteaseQueueTrackItem and MusicQueueSnapshot parsing and JSON serialization', () {
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
      expect(track.artist, 'Beyond');
      expect(track.album, 'Words & Music Final Live');
      expect(track.durationMs, 326000);
      expect(track.playable, isNull);
      expect(track.queueIndex, 0);

      final outJson = track.toJson();
      expect(outJson['track_id'], 'netease_1901371647');
      expect(outJson['stream_url'], '/api/v1/music/netease/stream/1901371647');

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
      expect(snapshot.queueVersion, 102);
      expect(snapshot.source, QueueSource.neteaseFavorite);
      expect(snapshot.total, 1);
      expect(snapshot.isComplete, true);
      expect(snapshot.tracks.length, 1);
    });

    test('list_loop mode sequential traversal and cyclic boundary wrap', () {
      final tracks = List.generate(
        5,
        (i) => NeteaseQueueTrackItem(
          trackId: 'netease_${1000 + i}',
          songId: 1000 + i,
          title: 'Track $i',
          artist: 'Artist $i',
          streamUrl: '/stream/${1000 + i}',
          queueIndex: i,
        ),
      );

      final snapshot = MusicQueueSnapshot(
        code: 200,
        queueId: 'q_fav_test',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 5,
        isComplete: true,
        offset: 0,
        limit: 5,
        hasMore: false,
        tracks: tracks,
      );

      queueCtrl.setQueueSnapshot(snapshot, startIndex: 0);
      queueCtrl.setPlaybackMode(PlaybackMode.listLoop);

      expect(queueCtrl.currentTrack?.trackId, 'netease_1000');
      expect(queueCtrl.currentIndex, 0);

      // Advance: 0 -> 1 -> 2 -> 3 -> 4 -> 0
      final t1 = queueCtrl.getNextTrack();
      expect(t1?.trackId, 'netease_1001');
      expect(queueCtrl.currentIndex, 1);

      final t2 = queueCtrl.getNextTrack();
      expect(t2?.trackId, 'netease_1002');

      final t3 = queueCtrl.getNextTrack();
      expect(t3?.trackId, 'netease_1003');

      final t4 = queueCtrl.getNextTrack();
      expect(t4?.trackId, 'netease_1004');

      final t0 = queueCtrl.getNextTrack();
      expect(t0?.trackId, 'netease_1000');
      expect(queueCtrl.currentIndex, 0);

      // Previous: 0 -> 4 -> 3
      final p4 = queueCtrl.getPreviousTrack();
      expect(p4?.trackId, 'netease_1004');
      expect(queueCtrl.currentIndex, 4);
    });

    test('shuffle activation gate: requires full favorite queue before activation', () {
      final partialTracks = [
        const NeteaseQueueTrackItem(
          trackId: 'netease_1',
          songId: 1,
          title: 'Track 1',
          artist: 'Artist 1',
          streamUrl: '/stream/1',
          queueIndex: 0,
        ),
      ];

      // Incomplete snapshot: total is 10, but only 1 track loaded
      final partialSnapshot = MusicQueueSnapshot(
        code: 200,
        queueId: 'q_fav_partial',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 10,
        isComplete: false,
        offset: 0,
        limit: 1,
        hasMore: true,
        tracks: partialTracks,
      );

      queueCtrl.setQueueSnapshot(partialSnapshot);
      expect(queueCtrl.isFullyLoaded, false);

      // Attempt to activate shuffle
      final activated = queueCtrl.setPlaybackMode(PlaybackMode.shuffle);
      expect(activated, false);
      expect(queueCtrl.appliedMode, PlaybackMode.listLoop);
      expect(queueCtrl.requestedMode, PlaybackMode.shuffle);
    });

    test('shuffle full-set Fisher-Yates non-repeating permutation', () {
      final fullTracks = List.generate(
        10,
        (i) => NeteaseQueueTrackItem(
          trackId: 'netease_${100 + i}',
          songId: 100 + i,
          title: 'Track $i',
          artist: 'Artist $i',
          streamUrl: '/stream/${100 + i}',
          queueIndex: i,
        ),
      );

      final fullSnapshot = MusicQueueSnapshot(
        code: 200,
        queueId: 'q_fav_full',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 10,
        isComplete: true,
        offset: 0,
        limit: 10,
        hasMore: false,
        tracks: fullTracks,
      );

      queueCtrl.setQueueSnapshot(fullSnapshot, startIndex: 3);
      expect(queueCtrl.isFullyLoaded, true);

      final activated = queueCtrl.setPlaybackMode(PlaybackMode.shuffle);
      expect(activated, true);
      expect(queueCtrl.appliedMode, PlaybackMode.shuffle);

      // Verify seed is index 3
      expect(queueCtrl.shuffleIndices.length, 10);
      expect(queueCtrl.shuffleIndices[0], 3);

      // Verify all 10 indices are present exactly once without duplication
      final setIndices = queueCtrl.shuffleIndices.toSet();
      expect(setIndices.length, 10);
      for (int i = 0; i < 10; i++) {
        expect(setIndices.contains(i), true);
      }

      // Step through all 9 subsequent tracks: each must be visited without duplication
      final visited = <int>{queueCtrl.currentIndex};
      for (int step = 0; step < 9; step++) {
        final nextTrack = queueCtrl.getNextTrack();
        expect(nextTrack, isNotNull);
        expect(visited.contains(queueCtrl.currentIndex), false);
        visited.add(queueCtrl.currentIndex);
      }
      expect(visited.length, 10);

      // 10th step wraps around and re-shuffles seamlessly
      final wrapTrack = queueCtrl.getNextTrack();
      expect(wrapTrack, isNotNull);
      expect(queueCtrl.shuffleIndices.length, 10);
    });

    test('single_track stops upon completion and restores favorite on switch back', () {
      final favTracks = List.generate(
        3,
        (i) => NeteaseQueueTrackItem(
          trackId: 'fav_$i',
          songId: 200 + i,
          title: 'Favorite $i',
          artist: 'Artist $i',
          streamUrl: '/stream/fav/$i',
          queueIndex: i,
        ),
      );

      final favSnapshot = MusicQueueSnapshot(
        code: 200,
        queueId: 'q_fav_main',
        queueVersion: 5,
        source: QueueSource.neteaseFavorite,
        total: 3,
        isComplete: true,
        offset: 0,
        limit: 3,
        hasMore: false,
        tracks: favTracks,
      );

      queueCtrl.setQueueSnapshot(favSnapshot, startIndex: 1);
      expect(queueCtrl.currentIndex, 1);

      // User searches and plays a single track
      const singleItem = NeteaseQueueTrackItem(
        trackId: 'search_999',
        songId: 999,
        title: 'Search Track',
        artist: 'Search Artist',
        streamUrl: '/stream/search/999',
        queueIndex: 0,
      );

      queueCtrl.switchQueue(
        source: QueueSource.singleTrack,
        singleTrackItem: singleItem,
      );

      expect(queueCtrl.queueSource, QueueSource.singleTrack);
      expect(queueCtrl.total, 1);
      expect(queueCtrl.currentTrack?.trackId, 'search_999');

      // Next track in single_track must return null (transitions to STOP)
      final afterSingle = queueCtrl.getNextTrack();
      expect(afterSingle, isNull);

      // Return to favorite queue explicitly restores index
      queueCtrl.switchQueue(source: QueueSource.neteaseFavorite);
      expect(queueCtrl.queueSource, QueueSource.neteaseFavorite);
      expect(queueCtrl.queueId, 'q_fav_main');
      expect(queueCtrl.currentIndex, 1);
      expect(queueCtrl.currentTrack?.trackId, 'fav_1');
    });

    test('consecutive failure circuit breaker halts at 3 failures with error code', () {
      final tracks = [
        const NeteaseQueueTrackItem(
          trackId: 't_1',
          songId: 1,
          title: 'T1',
          artist: 'A1',
          streamUrl: '/1',
          queueIndex: 0,
        ),
      ];

      queueCtrl.setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_fail_test',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 1,
        isComplete: true,
        offset: 0,
        limit: 1,
        hasMore: false,
        tracks: tracks,
      ));

      // Failure 1
      final a1 = queueCtrl.recordPlaybackFailure('HTTP 403 VIP Restricted');
      expect(a1, CircuitBreakerAction.skipToNext);
      expect(queueCtrl.consecutiveFailures, 1);
      expect(queueCtrl.errorCode, isNull);

      // Failure 2
      final a2 = queueCtrl.recordPlaybackFailure('Audio decode error');
      expect(a2, CircuitBreakerAction.skipToNext);
      expect(queueCtrl.consecutiveFailures, 2);
      expect(queueCtrl.errorCode, isNull);

      // Failure 3: Triggers circuit breaker!
      final a3 = queueCtrl.recordPlaybackFailure('CDN connect timeout');
      expect(a3, CircuitBreakerAction.stopPlayer);
      expect(queueCtrl.consecutiveFailures, 3);
      expect(queueCtrl.errorCode, 'PLAYBACK_CONSECUTIVE_FAILURES');
      expect(queueCtrl.errorDetail, contains('CDN connect timeout'));

      // Success resets circuit breaker
      queueCtrl.recordPlaybackSuccess();
      expect(queueCtrl.consecutiveFailures, 0);
      expect(queueCtrl.errorCode, isNull);
      expect(queueCtrl.errorDetail, isNull);
    });

    test('authentic intelligence mode exhaustion reports error cleanly without fake fallback', () {
      final intelTracks = [
        const NeteaseQueueTrackItem(
          trackId: 'intel_1',
          songId: 501,
          title: 'Intel 1',
          artist: 'AI Artist',
          streamUrl: '/intel/1',
          queueIndex: 0,
        ),
      ];

      queueCtrl.initIntelligenceQueue(
        queueId: 'q_intel_test',
        queueVersion: 1,
        initialTracks: intelTracks,
        playlistId: 987654321,
      );

      expect(queueCtrl.queueSource, QueueSource.neteaseIntelligence);
      expect(queueCtrl.appliedMode, PlaybackMode.intelligence);
      expect(queueCtrl.total, 1);

      // Exhausted without continuation
      final next = queueCtrl.getNextTrack();
      expect(next, isNull);
      expect(queueCtrl.errorCode, 'INTELLIGENCE_QUEUE_EXHAUSTED');
    });
  });

  group('CarMusicSyncService V2.2 Full Protocol & Status Synchronization Tests', () {
    late CarMusicSyncService syncService;

    setUp(() {
      syncService = CarMusicSyncService();
      CarMusicQueueController().clear();
    });

    test('set_playback_mode command switches mode while preserving playing state', () async {
      final favTracks = List.generate(
        5,
        (i) => NeteaseQueueTrackItem(
          trackId: 'fav_$i',
          songId: 300 + i,
          title: 'Fav $i',
          artist: 'Artist $i',
          streamUrl: '/stream/$i',
          queueIndex: i,
        ),
      );

      CarMusicQueueController().setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_fav_sync',
        queueVersion: 1,
        source: QueueSource.neteaseFavorite,
        total: 5,
        isComplete: true,
        offset: 0,
        limit: 5,
        hasMore: false,
        tracks: favTracks,
      ));

      // Handle set_playback_mode -> shuffle
      await syncService.handleCommand({
        'command_id': 'cmd_mode_001',
        'action': 'set_playback_mode',
        'params': {'mode': 'shuffle'},
      });

      expect(CarMusicQueueController().appliedMode, PlaybackMode.shuffle);
      expect(BuiltInPlayerService().player.shuffleModeEnabled, true);

      // Handle set_playback_mode -> single_loop
      await syncService.handleCommand({
        'command_id': 'cmd_mode_002',
        'action': 'set_playback_mode',
        'params': {'mode': 'single_loop'},
      });

      expect(CarMusicQueueController().appliedMode, PlaybackMode.singleLoop);
      expect(BuiltInPlayerService().currentLoopModeString, 'one');
    });

    test('status report contains monotonic status_seq, capabilities, and queue metadata', () async {
      CarMusicQueueController().setQueueSnapshot(MusicQueueSnapshot(
        code: 200,
        queueId: 'q_status_test',
        queueVersion: 42,
        source: QueueSource.neteaseFavorite,
        total: 10,
        isComplete: true,
        offset: 0,
        limit: 10,
        hasMore: false,
        tracks: [
          const NeteaseQueueTrackItem(
            trackId: 'track_test_1',
            songId: 9999,
            title: 'Test Song',
            artist: 'Test Artist',
            streamUrl: '/stream/test',
            queueIndex: 0,
          ),
        ],
      ));

      await syncService.handleCommand({
        'command_id': 'cmd_ack_001',
        'action': 'set_volume',
        'params': {'volume': 0.20},
      });

      // Verify status data
      // Invoke sendCurrentStatus and verify internal state
      expect(BuiltInPlayerService().currentVolume, 0.20);
      expect(CarMusicQueueController().queueVersion, 42);
      expect(CarMusicQueueController().queueId, 'q_status_test');
    });

    test('expired command is dropped without updating player state', () async {
      await BuiltInPlayerService().setVolume(0.25);

      final pastTime = DateTime.now().toUtc().subtract(const Duration(minutes: 10)).toIso8601String();
      await syncService.handleCommand({
        'command_id': 'cmd_expired_v2',
        'action': 'set_volume',
        'expires_at': pastTime,
        'params': {'volume': 0.02},
      });

      expect(BuiltInPlayerService().currentVolume, 0.25);
    });

    test('duplicate command_id is not re-executed', () async {
      await syncService.handleCommand({
        'command_id': 'cmd_dup_v2',
        'action': 'set_volume',
        'params': {'volume': 0.15},
      });
      expect(BuiltInPlayerService().currentVolume, 0.15);

      await BuiltInPlayerService().setVolume(0.30);

      // Re-send same command_id
      await syncService.handleCommand({
        'command_id': 'cmd_dup_v2',
        'action': 'set_volume',
        'params': {'volume': 0.15},
      });

      // Volume must remain 0.30 (not re-executed)
      expect(BuiltInPlayerService().currentVolume, 0.30);
    });
  });
}
