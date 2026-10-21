import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_yaris/services/backend_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart' as platform;
import 'package:my_yaris/models/music_queue_models.dart';
import 'package:my_yaris/services/built_in_player_service.dart';
import 'package:my_yaris/services/car_music_queue_controller.dart';
import 'package:my_yaris/services/car_music_sync_service.dart';
import 'package:my_yaris/services/in_app_audio_stream_proxy.dart';
import 'car_music_queue_controller_test.dart' as support;

class NativeTestHttpOverrides extends HttpOverrides {}

class ObservedPlatform extends support.FakeJustAudioPlatform {
  ObservedPlayer? latest;
  @override
  Future<platform.AudioPlayerPlatform> init(platform.InitRequest request) async {
    final player = ObservedPlayer(request.id);
    players[request.id] = player;
    latest = player;
    return player;
  }
}

class ObservedPlayer extends support.FakeAudioPlayerPlatform {
  ObservedPlayer(super.id);
  int loads = 0, plays = 0;
  @override
  Future<platform.LoadResponse> load(platform.LoadRequest request) async {
    loads++;
    return super.load(request);
  }
  @override
  Future<platform.PlayResponse> play(platform.PlayRequest request) async {
    plays++;
    return super.play(request);
  }
}

Map<String, dynamic> page(Map<String, String> query, {int count = 137, String source = 'netease_favorite', int version = 17}) {
  final offset = int.parse(query['offset']!);
  final end = (offset + 50).clamp(0, count);
  return {
    'queue_id': source == 'netease_intelligence' ? 'q_intel_real' : 'q_fav_full',
    'queue_version': version, 'source': source, 'total': count,
    'is_complete': source != 'netease_intelligence', 'batch_index': 0,
    'offset': offset, 'limit': 50, 'has_more': end < count, 'queue_state': 'ready',
    'tracks': [for (var i = offset; i < end; i++) {
      'track_id': 'netease_${1000 + i}', 'song_id': 1000 + i,
      'title': 'Track $i', 'artist': 'Test', 'queue_index': i,
      'stream_url': '/api/v1/music/netease/stream/${1000 + i}',
    }],
  };
}

Future<void> settle() async {
  await Future<void>.delayed(const Duration(milliseconds: 15));
  await BuiltInPlayerService().serialize(() async {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final audio = ObservedPlatform();
  final ctrl = CarMusicQueueController();
  final sync = CarMusicSyncService();
  final engine = BuiltInPlayerService();
  setUpAll(() {
    platform.JustAudioPlatform.instance = audio;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (_) async => null);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (_) async => '/tmp');
  });
  setUp(() { ctrl.clear(); });
  tearDown(() async {
    sync.stop();
    await engine.stop();
    await InAppAudioStreamProxy().stop();
  });
  void start(support.FakeBackendClient client) => sync.start(baseUrl: 'https://backend.example.com',
    deviceId: 'car_test', token: 'test-token', backendClient: client, autoConnect: false);

  test('cold startup is silent, complete 137 tracks cross pages; paused nonzero cursor survives loop/shuffle and resume', () async {
    var reads = 0;
    final client = support.FakeBackendClient(onFetchQueue: (_, query) { reads++; return page(query); });
    start(client);
    await engine.init();
    expect(engine.player.playing, false);
    expect(reads, 0);
    expect(engine.player.audioSource, isNull);
    await sync.restoreStatusSnapshot({'queue_id': 'q_fav_full', 'queue_version': 17,
      'queue_source': 'netease_favorite', 'current_index': 120, 'current_track_id': 'netease_1120',
      'applied_mode': 'list_loop', 'position_ms': 45000});
    expect(engine.player.audioSource, isNull);
    expect(engine.player.playing, false);
    expect(ctrl.currentIndex, 120);
    await sync.handleCommand({'command_id': 'full_cold', 'action': 'resume', 'params': {
      'queue_id': 'q_fav_full', 'queue_version': 17, 'source': 'netease_favorite',
      'track_id': 'netease_1120', 'queue_index': 120, 'restore_position_ms': 45000,
    }});
    expect(reads, 3);
    expect(ctrl.tracks.length, 137);
    expect(ctrl.currentIndex, 120);
    expect(engine.currentTrack.id, 'netease_1120');
    expect(audio.latest!.loads, 1);
    expect(engine.player.loopMode, LoopMode.off);
    await sync.handleCommand({'command_id': 'pause_full', 'action': 'pause'});
    final loads = audio.latest!.loads;
    final pausedPosition = engine.player.position.inMilliseconds;
    for (final mode in ['shuffle', 'list_loop', 'shuffle']) {
      await sync.handleCommand({'command_id': 'mode_$mode${ctrl.appliedMode.value}', 'action': 'set_playback_mode',
        'params': {'mode': mode, 'queue_id': 'q_fav_full', 'queue_version': 17, 'source': 'netease_favorite'}});
      expect(ctrl.currentIndex, 120);
      expect(engine.player.playing, false);
      expect(engine.player.position.inMilliseconds, pausedPosition);
    }
    expect(audio.latest!.loads, loads);
    final seen = {ctrl.currentTrack!.trackId};
    for (var i = 0; i < 136; i++) { seen.add(ctrl.getNextTrack()!.trackId); }
    expect(seen.length, 137);
    expect(seen, contains('netease_1136'));
    ctrl.selectTrackByIndex(120);
    await sync.handleCommand({'command_id': 'same_resume', 'action': 'resume', 'params': {
      'queue_id': 'q_fav_full', 'queue_version': 17, 'source': 'netease_favorite',
      'track_id': 'netease_1000', 'restore_position_ms': 0,
    }});
    expect(ctrl.currentIndex, 120);
    expect(engine.player.position.inMilliseconds, greaterThanOrEqualTo(45000));
    expect(audio.latest!.loads, loads);
  });

  test('true intelligence is accepted with open-ended metadata and continuation carries binding fields; no fallback', () async {
    Map<String, dynamic>? request;
    final client = support.FakeBackendClient(onFetchQueue: (_, query) => page(query, count: 2, source: 'netease_intelligence'),
      onPostIntelligence: (body) {
        request = body;
        return {...page({'offset': '0'}, count: 4, source: 'netease_intelligence', version: 39), 'mode': 'intelligence', 'batch_index': 1};
      });
    start(client);
    await sync.handleCommand({'command_id': 'true_heart', 'action': 'set_playback_mode', 'params': {
      'mode': 'intelligence', 'source': 'netease_intelligence', 'queue_id': 'q_intel_real', 'queue_version': 17,
    }});
    expect(ctrl.appliedMode, PlaybackMode.intelligence);
    expect(ctrl.isFullyLoaded, true);
    expect(engine.player.playing, false);
    await sync.handleCommand({'command_id': 'heart_play', 'action': 'resume'});
    await sync.handleCommand({'command_id': 'heart_next', 'action': 'next'});
    expect(request!['device_id'], 'car_test');
    expect(request!['queue_id'], 'q_intel_real');
    expect(request!['queue_version'], 17);
    expect(request!['batch_index'], 1);
    expect(ctrl.queueVersion, 39);
    expect(ctrl.currentIndex, 1);
    expect(ctrl.queueSource, QueueSource.neteaseIntelligence);
    client.onPostIntelligence = (_) => throw StateError('fake upstream failure');
    await ctrl.continueIntelligenceBatchForTesting();
    expect(ctrl.queueSource, QueueSource.neteaseIntelligence);
    expect(ctrl.queueVersion, 39);
    expect(ctrl.errorCode, isNotNull);
  });

  test('concurrent HTTP/WS envelopes execute serially; duplicates do not replay; unknown commands fail', () async {
    final results = <String>[];
    start(support.FakeBackendClient(onFetchQueue: (_, query) => page(query, count: 3), onAck: (id, status, _) {
      if (status != 'received') results.add('$id:$status');
    }));
    await Future.wait([
      sync.handleCommand({'command_id': 'serial_play', 'action': 'resume', 'params': {'queue_id': 'q_fav_full', 'queue_version': 17}}),
      sync.handleCommand({'type': 'music_command', 'data': {'command_id': 'serial_pause', 'action': 'pause'}}),
      sync.handleCommand({'command_id': 'serial_next', 'action': 'next'}),
    ]);
    expect(results, ['serial_play:applied', 'serial_pause:applied', 'serial_next:applied']);
    expect(ctrl.currentIndex, 1);
    expect(engine.player.playing, false);
    final loads = audio.latest!.loads;
    await sync.handleCommand({'command_id': 'serial_play', 'action': 'resume'});
    expect(audio.latest!.loads, loads);
    expect(engine.player.playing, false);
    await sync.handleCommand({'command_id': 'unsupported', 'action': 'fake_success'});
    expect(results.last, 'unsupported:failed');
  });

  test('native completed event advances once, explicit single stops, single to favorite preserves same song position', () async {
    start(support.FakeBackendClient(onFetchQueue: (_, query) => page(query, count: 3)));
    await sync.handleCommand({'command_id': 'completion_play', 'action': 'resume', 'params': {'queue_id': 'q_fav_full', 'queue_version': 17}});
    // Emitted by the native platform stream, through just_audio and the real service listener.
    audio.latest!.complete();
    audio.latest!.complete();
    await settle();
    expect(ctrl.currentIndex, 1);
    expect(engine.currentTrack.id, 'netease_1001');
    final current = ctrl.currentTrack!;
    ctrl.switchQueue(source: QueueSource.singleTrack, singleTrackItem: current);
    audio.latest!.complete();
    await settle();
    expect(engine.player.playing, false);
    expect(engine.stopped, true);
    await engine.playQueueTrack(current, initialPosition: const Duration(seconds: 25), startPlaying: false);
    final loads = audio.latest!.loads;
    await sync.handleCommand({'command_id': 'back_to_favorite', 'action': 'set_playback_mode', 'params': {
      'mode': 'list_loop', 'source': 'netease_favorite', 'queue_id': 'q_fav_full', 'queue_version': 17}});
    expect(ctrl.queueSource, QueueSource.neteaseFavorite);
    expect(ctrl.currentIndex, 1);
    expect(audio.latest!.loads, loads);
    expect(engine.player.position.inSeconds, 25);
    expect(engine.player.playing, false);
  });

  test('three unavailable streams stop with visible reason and never use samples', () async {
    start(support.FakeBackendClient(onFetchQueue: (_, query) => page(query, count: 4)));
    await sync.handleCommand({'command_id': 'failure_setup', 'action': 'resume', 'params': {'queue_id': 'q_fav_full', 'queue_version': 17}});
    final old = ctrl.createBackup();
    final failed = old.tracks.map((t) => t.copyWith(streamUrl: '/api/v1/music/stream/invalid-stream')).toList();
    ctrl.setQueueSnapshot(MusicQueueSnapshot(code: 200, queueId: old.queueId, queueVersion: old.queueVersion,
      source: old.queueSource, total: 4, isComplete: true, offset: 0, limit: 4, hasMore: false, tracks: failed));
    await engine.serialize(() => engine.playQueueTrack(ctrl.currentTrack!));
    expect(ctrl.consecutiveFailures, 3);
    expect(ctrl.errorCode, 'PLAYBACK_CONSECUTIVE_FAILURES');
    expect(engine.player.playing, false);
    expect(engine.stopped, true);
    expect(engine.currentTrack.isLocal, false);
  });
  test('explicit default resume skips unavailable media and ACK reports the actual cursor', () async {
    String? terminal;
    bool allFail = false;
    int? actualIndex;
    start(support.FakeBackendClient(onFetchQueue: (_, query) {
      final result = page(query, count: 4);
      (result['tracks'] as List)[0]['stream_url'] = '/api/v1/music/stream/invalid-stream';
      if (allFail) {
        result['queue_id'] = 'q_fav_failure';
        result['queue_version'] = 18;
        for (final track in result['tracks'] as List) { track['stream_url'] = '/api/v1/music/stream/invalid-stream'; }
      }
      return result;
    }, onAck: (_, status, payload) { if (status != 'received') { terminal = status; actualIndex = payload['current_index'] as int?; } }));
    await sync.handleCommand({'command_id': 'bounded_explicit', 'action': 'resume', 'params': {
      'queue_id': 'q_fav_full', 'queue_version': 17, 'source': 'netease_favorite'}});
    expect(terminal, 'applied');
    expect(actualIndex, 1);
    expect(ctrl.currentIndex, 1);
    expect(engine.currentTrack.id, 'netease_1001');
    await engine.seek(const Duration(seconds: 15));
    allFail = true;
    await sync.handleCommand({'command_id': 'bounded_failed_rollback', 'action': 'play_track', 'params': {
      'queue_id': 'q_fav_failure', 'queue_version': 18, 'source': 'netease_favorite', 'track_id': 'netease_1000'}});
    expect(terminal, 'failed');
    expect(ctrl.queueId, 'q_fav_full');
    expect(ctrl.queueVersion, 17);
    expect(ctrl.currentIndex, 1);
    expect(engine.currentTrack.id, 'netease_1001');
    expect(engine.player.position.inSeconds, greaterThanOrEqualTo(15));
    expect(engine.player.playing, true);
  });

  test('phone to car handoff prepare loads paused at the position, keeps mode and cursor, and resume is the only sound', () async {
    String? terminal;
    int? actualIndex;
    String? appliedMode;
    start(support.FakeBackendClient(onFetchQueue: (_, query) => page(query),
      onAck: (_, status, payload) { if (status != 'received') { terminal = status; actualIndex = payload['current_index'] as int?; appliedMode = payload['applied_mode'] as String?; } }));
    await engine.init();
    final observed = audio.latest, plays = observed?.plays ?? 0;
    await sync.handleCommand({'command_id': 'ho_prepare_fav', 'action': 'play_track', 'params': {
      'queue_id': 'q_fav_full', 'queue_version': 17, 'source': 'netease_favorite', 'track_id': 'netease_1090',
      'queue_index': 90, 'seek_ms': 61000, 'autoplay': false, 'mode': 'shuffle'}});
    expect(terminal, 'applied');
    expect(actualIndex, 90);
    expect(appliedMode, 'shuffle');
    expect(ctrl.appliedMode.value, 'shuffle');
    expect(ctrl.tracks.length, 137);
    expect(engine.currentTrack.id, 'netease_1090');
    expect(engine.player.position.inMilliseconds, 61000);
    expect(engine.player.playing, false, reason: 'prepare must stay silent');
    expect(audio.latest!.plays, identical(audio.latest, observed) ? plays : 0, reason: 'no play() call during prepare');
    await sync.handleCommand({'command_id': 'ho_resume_fav', 'action': 'resume', 'params': {}});
    expect(terminal, 'applied');
    expect(engine.player.playing, true);
    expect(engine.currentTrack.id, 'netease_1090');
    expect(engine.player.position.inMilliseconds, greaterThanOrEqualTo(61000));
    // Default play_track (no autoplay field) still starts immediately, and a loop request is honoured.
    await sync.handleCommand({'command_id': 'plain_play', 'action': 'play_track', 'params': {
      'queue_id': 'q_fav_full', 'queue_version': 17, 'source': 'netease_favorite', 'track_id': 'netease_1005',
      'queue_index': 5, 'mode': 'list_loop'}});
    expect(engine.player.playing, true);
    expect(ctrl.appliedMode.value, 'list_loop');
  });

  test('a failed handoff prepare keeps the previous queue, cursor and silence', () async {
    String? terminal;
    var failing = false;
    start(support.FakeBackendClient(onFetchQueue: (_, query) {
      if (failing) throw BackendException(404, 'gone');
      return page(query);
    }, onAck: (_, status, payload) { if (status != 'received') terminal = status; }));
    await engine.init();
    await sync.handleCommand({'command_id': 'ho_base', 'action': 'play_track', 'params': {
      'queue_id': 'q_fav_full', 'queue_version': 17, 'source': 'netease_favorite', 'track_id': 'netease_1010',
      'queue_index': 10, 'autoplay': false, 'seek_ms': 5000}});
    expect(terminal, 'applied');
    failing = true;
    await sync.handleCommand({'command_id': 'ho_prepare_broken', 'action': 'play_track', 'params': {
      'queue_id': 'q_fav_other', 'queue_version': 19, 'source': 'netease_favorite', 'track_id': 'netease_1020',
      'queue_index': 20, 'autoplay': false, 'seek_ms': 9000}});
    expect(terminal, 'failed');
    expect(ctrl.queueId, 'q_fav_full');
    expect(ctrl.currentIndex, 10);
    expect(engine.player.playing, false);
  });

  test('status sequence persists across fresh services and clock watermark; concurrent snapshots are ordered', () async {
    SharedPreferences.setMockInitialValues({'music_status_seq_': 9000000000000000});
    final first = CarMusicSyncService.forTesting();
    final before = await first.statusSnapshotForTesting();
    final restarted = CarMusicSyncService.forTesting();
    final values = await Future.wait([restarted.statusSnapshotForTesting(), restarted.statusSnapshotForTesting()]);
    expect(values[0]['status_seq'], greaterThan(before['status_seq'] as int));
    expect(values[1]['status_seq'], greaterThan(values[0]['status_seq'] as int));
    expect(values[1]['updated_at'], isA<int>());
  });

  test('HTTP intelligence adapter transmits device, queue, version and deterministic batch request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Map<String, dynamic>>();
    server.listen((req) async {
      received.complete(jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'mode': 'intelligence', 'queue_id': 'q_intel_wire', 'queue_version': 22}));
      await req.response.close();
    });
    final nativeHttp = HttpOverrides.runWithHttpOverrides(() => HttpClient(), NativeTestHttpOverrides());
    final client = BackendClient(httpClient: nativeHttp);
    try {
      final response = await client.requestIntelligenceBatch(baseUrl: 'http://127.0.0.1:${server.port}', token: 'fixture',
        deviceId: 'car_test', queueId: 'q_intel_wire', queueVersion: 17,
        requestId: 'req_batch_1', seedSongId: 12, batchIndex: 1);
      final payload = await received.future;
      expect(payload['device_id'], 'car_test');
      expect(payload['queue_id'], 'q_intel_wire');
      expect(payload['queue_version'], 17);
      expect(payload['request_id'], 'req_batch_1');
      expect(payload['batch_index'], 1);
      expect(response['queue_version'], 22);
    } finally { client.close(); await server.close(force: true); }
  });

}
