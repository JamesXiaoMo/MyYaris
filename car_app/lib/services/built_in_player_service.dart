import 'dart:async';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'in_app_audio_stream_proxy.dart';
import 'car_music_queue_controller.dart';
import '../models/music_queue_models.dart';

class LocalTrackItem {
  final String id;
  final String title;
  final String artist;
  final String assetPath;
  final bool isLocal;
  final String durationDesc;
  final String tag;

  const LocalTrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.assetPath,
    required this.isLocal,
    required this.durationDesc,
    required this.tag,
  });
}

class BuiltInPlayerService {
  static final BuiltInPlayerService _instance = BuiltInPlayerService._internal();
  factory BuiltInPlayerService() => _instance;
  BuiltInPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();
  AudioPlayer get player => _player;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  // Safe initial low volume to prevent blasting car speakers
  double _currentVolume = 0.25;
  double get currentVolume => _currentVolume;

  List<LocalTrackItem> get tracks => CarMusicQueueController().tracks.map((t) => LocalTrackItem(
    id: t.trackId, title: t.title, artist: t.artist, assetPath: t.streamUrl,
    isLocal: false, durationDesc: '${t.durationMs ~/ 1000}秒', tag: '网易云')).toList();

  Future<void> Function(String action, Map<String, dynamic> params)? requestUserCommand;
  Future<void> _operationTail = Future.value();
  bool _loadingSource = false;
  bool _recovering = false;
  bool _resumeAfterInterruption = false;
  bool _stopped = true;
  bool get stopped => _stopped;

  bool isTransitioning = false;
  void Function()? onStateSettled;

  Future<void> serialize(Future<void> Function() operation) {
    final result = _operationTail.then((_) async {
      isTransitioning = true;
      try { await operation(); }
      finally { isTransitioning = false; onStateSettled?.call(); }
    });
    _operationTail = result.catchError((Object _) {});
    return result;
  }

  LocalTrackItem? _activeRemoteTrack;
  LocalTrackItem? get activeRemoteTrack => _activeRemoteTrack;
  final ValueNotifier<LocalTrackItem?> activeRemoteTrackNotifier = ValueNotifier(null);

  String _currentBaseUrl = '';
  String _currentDeviceToken = '';

  void setServerConfig({required String baseUrl, required String token}) {
    _currentBaseUrl = baseUrl.trim();
    while (_currentBaseUrl.endsWith('/')) {
      _currentBaseUrl = _currentBaseUrl.substring(0, _currentBaseUrl.length - 1);
    }
    _currentDeviceToken = token.trim();
  }

  LocalTrackItem get currentTrack {
    if (_activeRemoteTrack != null) return _activeRemoteTrack!;
    final queueCtrl = CarMusicQueueController();
    final queueTrack = queueCtrl.currentTrack;
    if (queueTrack != null) {
      return LocalTrackItem(
        id: queueTrack.trackId,
        title: queueTrack.title,
        artist: queueTrack.artist,
        assetPath: queueTrack.streamUrl,
        isLocal: false,
        durationDesc: '${queueTrack.durationMs ~/ 1000}秒 • 在线流',
        tag: queueTrack.album ?? '网络歌单',
      );
    }
    return const LocalTrackItem(
      id: '',
      title: '无播放曲目',
      artist: '',
      assetPath: '',
      isLocal: false,
      durationDesc: '',
      tag: '',
    );
  }


  Future<void> init() async {
    if (_isInitialized) return;

    try {
      // 1. Configure audio session for car audio focus & ducking
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      // Listen to audio focus interruptions (e.g. NAVITIME voice guidance ducking or pause)
      session.interruptionEventStream.listen((event) {
        debugPrint('[BuiltInPlayer] Audio focus interruption event: begin=${event.begin}, type=${event.type}');
        if (event.begin) {
          _resumeAfterInterruption = _player.playing;
          switch (event.type) {
            case AudioInterruptionType.duck:
              debugPrint('[BuiltInPlayer] Audio focus ducking: lowering volume from $_currentVolume to ${_currentVolume * 0.5}');
              _player.setVolume((_currentVolume * 0.5).clamp(0.0, 1.0));
              break;
            case AudioInterruptionType.pause:
            case AudioInterruptionType.unknown:
              debugPrint('[BuiltInPlayer] Audio focus pause interruption.');
              _player.pause();
              break;
          }
        } else {
          switch (event.type) {
            case AudioInterruptionType.duck:
              debugPrint('[BuiltInPlayer] Audio focus unduck: restoring volume to $_currentVolume');
              _player.setVolume(_currentVolume);
              break;
            case AudioInterruptionType.pause:
              debugPrint('[BuiltInPlayer] Audio focus restored: resuming playback');
              if (_resumeAfterInterruption) unawaited(_player.play().catchError((Object _) {}));
              _resumeAfterInterruption = false;
              break;
            case AudioInterruptionType.unknown:
              break;
          }
        }
      });

      // Listen to player state: completed -> autonomous progression, playing -> record success
      _player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (!_loadingSource && !_stopped) {
            final source = _player.audioSource;
            unawaited(serialize(() async {
              if (source == _player.audioSource && !_stopped) await _handleTrackCompleted();
            }));
          }
        } else if (state.playing && state.processingState == ProcessingState.ready) {
          CarMusicQueueController().recordPlaybackSuccess();
        }
      });

      _player.playbackEventStream.listen((event) {
        // Stream event received
      }, onError: (Object e) {
        debugPrint('[BuiltInPlayer] Playback stream error');
        if (!_loadingSource && !_recovering && !_stopped) {
          unawaited(serialize(() => _handlePlaybackError('媒体流播放失败')));
        }
      });

      await _player.setVolume(_currentVolume);
      await _player.setLoopMode(LoopMode.off);
      await _player.setShuffleModeEnabled(false);

      // 3. Start in-app loopback proxy for ExoPlayer network requests
      try {
        await InAppAudioStreamProxy().start();
      } catch (e) {
        debugPrint('[BuiltInPlayer] InAppAudioStreamProxy start note: $e');
      }

      _isInitialized = true;
      debugPrint('[BuiltInPlayer] Initialized successfully with ${tracks.length} tracks.');
    } catch (e) {
      debugPrint('[BuiltInPlayer] Initialization error: $e');
      rethrow;
    }
  }

  Future<void> _handleTrackCompleted() async {
    debugPrint('[BuiltInPlayer] Track completed processingState. Checking next track in queue...');
    final queueCtrl = CarMusicQueueController();
    if (queueCtrl.tracks.isNotEmpty) {
      final nextTrack = await queueCtrl.nextTrackForPlayback();
      if (nextTrack == null) {
        debugPrint('[BuiltInPlayer] No next track available. Stopping player.');
        await stop();
      } else {
        debugPrint('[BuiltInPlayer] Autonomous progression to next track: ${nextTrack.title} (${nextTrack.trackId})');
        await playQueueTrack(nextTrack);
      }
    } else {
      await stop();
    }
  }

  Future<void> _handlePlaybackError(String reason) async {
    if (_recovering) return;
    _recovering = true;
    try {
      final ctrl = CarMusicQueueController();
      while (true) {
        if (ctrl.recordPlaybackFailure(reason) == CircuitBreakerAction.stopPlayer) {
          await stop();
          return;
        }
        final next = await ctrl.nextTrackForPlayback();
        if (next == null) { await stop(); return; }
        try {
          await playQueueTrack(next, rethrowOnError: true);
          return;
        } catch (_) {
          reason = '媒体流不可播放';
        }
      }
    } finally { _recovering = false; }
  }

  /// Plays an online track from the active CarMusicQueueController
  Future<void> playQueueTrack(
    NeteaseQueueTrackItem track, {
    Duration? initialPosition,
    bool startPlaying = true,
    Map<String, String>? headers,
    bool rethrowOnError = false,
  }) async {
    if (!_isInitialized) await init();

    _loadingSource = true;
    try {
      if (track.playable == false) throw StateError('歌曲当前不可播放');
      String fullStreamUrl = track.streamUrl;
      if (fullStreamUrl.startsWith('/')) {
        fullStreamUrl = '$_currentBaseUrl$fullStreamUrl';
      }

      final streamUri = Uri.parse(fullStreamUrl);
      final backendUri = Uri.parse(_currentBaseUrl);
      if (streamUri.scheme != 'https' || streamUri.host.isEmpty ||
          streamUri.userInfo.isNotEmpty || streamUri.host != backendUri.host ||
          streamUri.port != backendUri.port) {
        throw StateError('媒体流地址不受信任，需要后端 HTTPS 代理');
      }
      final token = headers?['X-Device-Token'] ??
          headers?['Authorization']?.replaceAll('Bearer ', '') ??
          _currentDeviceToken;

      final resolvedUrl = InAppAudioStreamProxy().resolveStreamUrl(
        fullStreamUrl,
        token: token,
      );
      final uri = Uri.parse(resolvedUrl);
      final source = AudioSource.uri(uri, headers: headers);
      // setAudioSource retains just_audio's playing flag; pause before preparing a paused mode.
      if (!startPlaying) await _player.pause();
      await _player.setLoopMode(LoopMode.off);
      await _player.setShuffleModeEnabled(false);
      await _player.setAudioSource(source, initialPosition: initialPosition ?? Duration.zero);
      _stopped = false;

      _activeRemoteTrack = LocalTrackItem(
        id: track.trackId,
        title: track.title,
        artist: track.artist,
        assetPath: track.streamUrl,
        isLocal: false,
        durationDesc: '${track.durationMs ~/ 1000}秒 • 在线流',
        tag: track.album ?? '网络歌单',
      );
      activeRemoteTrackNotifier.value = _activeRemoteTrack;

      if (startPlaying) {
        unawaited(_player.play().catchError((Object _) {}));
      }
    } catch (e) {
      debugPrint('[BuiltInPlayer] Queue media could not be prepared');
      if (rethrowOnError) {
        rethrow;
      }
      _loadingSource = false;
      await _handlePlaybackError('媒体流不可播放');
    } finally { _loadingSource = false; }
  }

  Future<void> play() async {
    if (!_isInitialized) await init();
    if (_activeRemoteTrack == null) throw StateError('请显式选择默认喜欢歌单播放');
    _stopped = false;
    unawaited(_player.play().catchError((Object _) {}));
  }

  Future<void> pause() async {
    _resumeAfterInterruption = false;
    await _player.pause();
  }

  Future<void> stop() async {
    _stopped = true;
    await _player.pause();
    await _player.stop();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> skipToNext() async {
    final queueCtrl = CarMusicQueueController();
    if (queueCtrl.tracks.isNotEmpty) {
      final nextTrack = await queueCtrl.nextTrackForPlayback();
      if (nextTrack != null) {
        await playQueueTrack(nextTrack, startPlaying: _player.playing);
      } else {
        await stop();
      }
      return;
    }

    await stop();
  }

  Future<void> skipToPrevious() async {
    final previous = CarMusicQueueController().getPreviousTrack();
    if (previous == null) { await stop(); return; }
    await playQueueTrack(previous, startPlaying: _player.playing);
  }

  Future<void> selectTrack(int index) async {
    if (index < 0 || index >= tracks.length) return;
    await requestUserCommand?.call('play_track', {'source': CarMusicQueueController().queueSource,
      'queue_id': CarMusicQueueController().queueId, 'queue_version': CarMusicQueueController().queueVersion,
      'track_id': tracks[index].id, 'queue_index': index});
  }

  String get currentLoopModeString => CarMusicQueueController().appliedMode == PlaybackMode.singleLoop ? 'one' : 'all';

  Future<void> setLoopModeString(String mode) async {
    if (!CarMusicQueueController().setPlaybackMode(PlaybackMode.fromString(mode))) {
      throw StateError('当前队列无法使用该模式，请选择喜欢歌单或真实心动队列');
    }
    await _player.setLoopMode(LoopMode.off);
    await _player.setShuffleModeEnabled(false);
  }

  Future<void> setShuffle(bool enabled) => setLoopModeString(enabled ? 'shuffle' : 'list_loop');

  Future<void> setVolume(double val) async {
    _currentVolume = val.clamp(0.0, 1.0);
    await _player.setVolume(_currentVolume);
  }

  Future<void> dispose() async {
    await _player.dispose();
    _isInitialized = false;
  }
}
