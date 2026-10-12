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
      final url = client.buildLocalStreamUrl('http://192.0.2.10:8000', 'track_42');
      expect(url, 'http://192.0.2.10:8000/api/v1/music/stream/track_42');
    });

    test('buildNeteaseStreamUrl constructs standard V2 NetEase stream URL', () {
      final url = client.buildNeteaseStreamUrl('http://192.0.2.10:8000', '1901371647');
      expect(url, 'http://192.0.2.10:8000/api/v1/music/netease/stream/1901371647');
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

    test('currentLoopModeString maps loop modes correctly', () async {
      await playerService.setLoopModeString('one');
      expect(playerService.currentLoopModeString, 'one');

      await playerService.setLoopModeString('off');
      expect(playerService.currentLoopModeString, 'off');

      await playerService.setLoopModeString('all');
      expect(playerService.currentLoopModeString, 'all');
    });

    test('Volume clamping limits values between 0.0 and 1.0', () async {
      await playerService.setVolume(1.5);
      expect(playerService.currentVolume, 1.0);

      await playerService.setVolume(-0.5);
      expect(playerService.currentVolume, 0.0);

      await playerService.setVolume(0.25);
      expect(playerService.currentVolume, 0.25);
    });

    test('currentTrack falls back to default local track when no remote track is playing', () {
      expect(playerService.currentTrack.id, isNotEmpty);
      expect(playerService.currentTrack.isLocal, true);
    });
  });

  group('CarMusicSyncService Remote Command Dispatching Tests', () {
    late CarMusicSyncService syncService;

    setUp(() {
      syncService = CarMusicSyncService();
    });

    test('handleCommand dispatches pause and resume cleanly', () async {
      await syncService.handleCommand({'action': 'pause'});
      expect(syncService.lastCommandNotifier.value, contains('pause'));

      await syncService.handleCommand({'action': 'resume'});
      expect(syncService.lastCommandNotifier.value, contains('resume'));
    });

    test('handleCommand dispatches set_volume cleanly', () async {
      await syncService.handleCommand({
        'action': 'set_volume',
        'params': {'volume': 0.35},
      });
      expect(BuiltInPlayerService().currentVolume, 0.35);
    });

    test('handleCommand dispatches set_loop_mode cleanly', () async {
      await syncService.handleCommand({
        'action': 'set_loop',
        'params': {'loop_mode': 'one'},
      });
      expect(BuiltInPlayerService().currentLoopModeString, 'one');
    });

    test('handleCommand dispatches seek and stop cleanly', () async {
      await syncService.handleCommand({
        'action': 'seek',
        'params': {'seek_ms': 500},
      });
      expect(syncService.lastCommandNotifier.value, contains('seek'));

      await syncService.handleCommand({'action': 'stop'});
      expect(syncService.lastCommandNotifier.value, contains('stop'));
    });
  });
}
