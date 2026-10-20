import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/backend_client.dart';
import 'package:my_yaris/services/built_in_player_service.dart';
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

  group('BackendClient V2 API Compatibility Tests', () {
    late BackendClient client;

    setUp(() {
      client = BackendClient();
    });

    tearDown(() {
      client.close();
    });

    test('buildLocalStreamUrl constructs standard V2 HTTP 206 stream URL', () {
      final url = client.buildLocalStreamUrl('http://192.0.2.1:8000', 'track_42');
      expect(url, 'http://192.0.2.1:8000/api/v1/music/stream/track_42');
    });

    test('buildNeteaseStreamUrl constructs standard V2 NetEase stream URL', () {
      final url = client.buildNeteaseStreamUrl('http://192.0.2.1:8000', '1901371647');
      expect(url, 'http://192.0.2.1:8000/api/v1/music/netease/stream/1901371647');
    });

    test('buildLocalStreamUrl handles trailing slashes in baseUrl gracefully', () {
      final url = client.buildLocalStreamUrl('https://example.com/api///', 'abc');
      expect(url, 'https://example.com/api/api/v1/music/stream/abc');
    });
  });

  group('BuiltInPlayerService Dynamic Stream & Mode Tests', () {
    late BuiltInPlayerService playerService;

    setUp(() {
      playerService = BuiltInPlayerService();
    });

    test('Volume clamping limits values between 0.0 and 1.0', () async {
      await playerService.setVolume(1.5);
      expect(playerService.currentVolume, 1.0);

      await playerService.setVolume(-0.5);
      expect(playerService.currentVolume, 0.0);

      await playerService.setVolume(0.25);
      expect(playerService.currentVolume, 0.25);
    });

    test('currentTrack has no local fallback when no queue is selected', () {
      expect(playerService.currentTrack.id, isEmpty);
      expect(playerService.currentTrack.isLocal, false);
    });
  });

  group('CarMusicSyncService Remote Command Dispatching & Envelope Tests', () {
    late CarMusicSyncService syncService;

    setUp(() {
      syncService = CarMusicSyncService();
    });

    test('handleCommand unwraps {"type": "music_command", "data": {...}} envelope', () async {
      await syncService.handleCommand({
        'type': 'music_command',
        'timestamp': '2026-10-12T12:00:00Z',
        'data': {
          'command_id': 'cmd_ws_001',
          'action': 'set_volume',
          'params': {'volume': 0.22},
        },
      });
      expect(BuiltInPlayerService().currentVolume, 0.22);
      expect(syncService.lastCommandNotifier.value, contains('set_volume'));
    });

    test('handleCommand handles direct root command payload (HTTP long poll fallback)', () async {
      await syncService.handleCommand({
        'command_id': 'cmd_http_002',
        'action': 'set_volume',
        'params': {'volume': 0.18},
      });
      expect(BuiltInPlayerService().currentVolume, 0.18);
    });

    test('handleCommand deduplicates identical command_id across channels', () async {
      // First invocation executes command
      await syncService.handleCommand({
        'command_id': 'cmd_dup_test',
        'action': 'set_volume',
        'params': {'volume': 0.12},
      });
      expect(BuiltInPlayerService().currentVolume, 0.12);

      // Manually set volume to 0.20
      await BuiltInPlayerService().setVolume(0.20);
      expect(BuiltInPlayerService().currentVolume, 0.20);

      // Second invocation with same command_id is ignored (volume should remain 0.20)
      await syncService.handleCommand({
        'command_id': 'cmd_dup_test',
        'action': 'set_volume',
        'params': {'volume': 0.12},
      });
      expect(BuiltInPlayerService().currentVolume, 0.20);
    });

    test('handleCommand drops stale expired command when expires_at is past', () async {
      await BuiltInPlayerService().setVolume(0.20);
      expect(BuiltInPlayerService().currentVolume, 0.20);

      final expiredTime = DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String();
      await syncService.handleCommand({
        'command_id': 'cmd_expired_001',
        'action': 'set_volume',
        'expires_at': expiredTime,
        'params': {'volume': 0.05},
      });

      // Volume should not change to 0.05 because command expired
      expect(BuiltInPlayerService().currentVolume, 0.20);
    });

    test('handleCommand cleanly rejects empty action without crashing', () async {
      syncService.lastCommandNotifier.value = '初始状态';
      await syncService.handleCommand({
        'command_id': 'cmd_empty',
        'action': '',
      });
      expect(syncService.lastCommandNotifier.value, '初始状态');

      await syncService.handleCommand({
        'data': {'action': '   '},
      });
      expect(syncService.lastCommandNotifier.value, '初始状态');
    });

    test('legacy local sample is rejected while supported controls stay explicit', () async {
      // 1. play_track with local track id
      await syncService.handleCommand({
        'action': 'play_track',
        'params': {'track_id': 'local_2'},
      });
      expect(BuiltInPlayerService().currentTrack.id, isEmpty);
      expect(syncService.lastCommandNotifier.value, contains('指令失败'));

      // 2. pause
      await syncService.handleCommand({'action': 'pause'});
      expect(syncService.lastCommandNotifier.value, contains('pause'));

      // 3. resume
      await syncService.handleCommand({'action': 'resume'});
      expect(syncService.lastCommandNotifier.value, contains('resume'));

      // 4. next
      await syncService.handleCommand({'action': 'next'});
      expect(syncService.lastCommandNotifier.value, contains('next'));

      // 5. prev
      await syncService.handleCommand({'action': 'prev'});
      expect(syncService.lastCommandNotifier.value, contains('prev'));

      // 6. seek
      await syncService.handleCommand({
        'action': 'seek',
        'params': {'position_ms': 1200},
      });
      expect(syncService.lastCommandNotifier.value, contains('seek'));

      // 7. set_loop
      await syncService.handleCommand({
        'action': 'set_loop',
        'params': {'mode': 'single'},
      });
      // Unsupported legacy local sample playback must never become an applied queue.

      // 8. set_shuffle
      await syncService.handleCommand({
        'action': 'set_shuffle',
        'params': {'shuffle': true},
      });
      expect(syncService.lastCommandNotifier.value, contains('set_shuffle'));

      // 9. set_volume
      await syncService.handleCommand({
        'action': 'set_volume',
        'params': {'volume': 0.25},
      });
      expect(BuiltInPlayerService().currentVolume, 0.25);
    });
  });
}
