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

  final List<LocalTrackItem> tracks = const [
    LocalTrackItem(
      id: 'local_1',
      title: '钟声清脆旋律 (Bell Melody)',
      artist: 'MyYaris 自制合成样本',
      assetPath: 'assets/audio/track1_bell_melody.wav',
      isLocal: true,
      durationDesc: '3.0秒 • 高频清亮',
      tag: 'Track 1',
    ),
    LocalTrackItem(
      id: 'local_2',
      title: '低音律动节拍 (Bass Groove)',
      artist: 'MyYaris 自制合成样本',
      assetPath: 'assets/audio/track2_bass_groove.wav',
      isLocal: true,
      durationDesc: '3.0秒 • 低频脉冲',
      tag: 'Track 2',
    ),
    LocalTrackItem(
      id: 'local_3',
      title: '温暖氛围和弦 (Ambient Pad)',
      artist: 'MyYaris 自制合成样本',
      assetPath: 'assets/audio/track3_ambient_pad.wav',
      isLocal: true,
      durationDesc: '4.0秒 • 弦乐铺底',
      tag: 'Track 3',
    ),
  ];

  LocalTrackItem? _activeRemoteTrack;
  LocalTrackItem? get activeRemoteTrack => _activeRemoteTrack;
  final ValueNotifier<LocalTrackItem?> activeRemoteTrackNotifier = ValueNotifier(null);
  int _selectedTrackIndex = 0;

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
    // Only if queue is completely uninitialized and empty (offline test mode), fallback to local test tracks
    if (queueCtrl.tracks.isEmpty) {
      final idx = _player.currentIndex ?? _selectedTrackIndex;
      if (idx >= 0 && idx < tracks.length) {
        return tracks[idx];
      }
      return tracks[0];
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
              _player.play();
              break;
            case AudioInterruptionType.unknown:
              break;
          }
        }
      });

      // Listen to player state: completed -> autonomous progression, playing -> record success
      _player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          _handleTrackCompleted();
        } else if (state.playing && state.processingState == ProcessingState.ready) {
          CarMusicQueueController().recordPlaybackSuccess();
        }
      });

      _player.playbackEventStream.listen((event) {
        // Stream event received
      }, onError: (Object e) {
        debugPrint('[BuiltInPlayer] Playback stream error: $e');
        _handlePlaybackError(e.toString());
      });

      // 2. Load audio sources with local offline items
      final audioSources = tracks.map<AudioSource>((t) {
        if (t.isLocal) {
          return AudioSource.asset(t.assetPath);
        } else {
          return AudioSource.uri(Uri.parse(t.assetPath));
        }
      }).toList();

      await _player.setAudioSources(audioSources, initialIndex: 0, initialPosition: Duration.zero);
      await _player.setVolume(_currentVolume);
      await _player.setLoopMode(LoopMode.all);

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
      final nextTrack = queueCtrl.getNextTrack();
      if (nextTrack == null) {
        debugPrint('[BuiltInPlayer] No next track available. Stopping player.');
        await stop();
      } else {
        debugPrint('[BuiltInPlayer] Autonomous progression to next track: ${nextTrack.title} (${nextTrack.trackId})');
        await playQueueTrack(nextTrack);
      }
    } else {
      if (_player.hasNext) {
        await _player.seekToNext();
      } else {
        await _player.seek(Duration.zero, index: 0);
      }
    }
  }

  Future<void> _handlePlaybackError(String reason) async {
    final action = CarMusicQueueController().recordPlaybackFailure(reason);
    if (action == CircuitBreakerAction.stopPlayer) {
      debugPrint('[BuiltInPlayer] Circuit breaker triggered! Stopping player.');
      await stop();
    } else {
      debugPrint('[BuiltInPlayer] Consecutive failure < 3. Skipping to next track...');
      await skipToNext();
    }
  }

  /// Plays an online track from the active CarMusicQueueController
  Future<void> playQueueTrack(
    NeteaseQueueTrackItem track, {
    Duration? initialPosition,
    bool startPlaying = true,
    Map<String, String>? headers,
  }) async {
    if (!_isInitialized) await init();

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

    try {
      String fullStreamUrl = track.streamUrl;
      if (fullStreamUrl.startsWith('/')) {
        fullStreamUrl = '$_currentBaseUrl$fullStreamUrl';
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
      await _player.setAudioSource(source, initialPosition: initialPosition ?? Duration.zero);
      if (startPlaying) {
        unawaited(_player.play());
      }
    } catch (e) {
      debugPrint('[BuiltInPlayer] Error loading queue track: $e');
      await _handlePlaybackError(e.toString());
    }
  }

  /// Plays a remote network audio stream URL (e.g. from R9000P /api/v1/music/stream or netease stream)
  Future<void> playRemoteStream(
    String streamUrl, {
    required String trackId,
    required String title,
    String artist = 'R9000P 媒体流',
    Map<String, String>? headers,
    Duration? initialPosition,
  }) async {
    if (!_isInitialized) await init();

    _activeRemoteTrack = LocalTrackItem(
      id: trackId,
      title: title,
      artist: artist,
      assetPath: streamUrl,
      isLocal: false,
      durationDesc: '网络流式音频',
      tag: '远程播控',
    );
    activeRemoteTrackNotifier.value = _activeRemoteTrack;

    final token = headers?['X-Device-Token'] ??
        headers?['Authorization']?.replaceAll('Bearer ', '') ??
        _currentDeviceToken;
    final resolvedUrl = InAppAudioStreamProxy().resolveStreamUrl(
      streamUrl,
      token: token,
    );
    final uri = Uri.parse(resolvedUrl);
    final source = AudioSource.uri(uri, headers: headers);
    await _player.setAudioSource(source, initialPosition: initialPosition ?? Duration.zero);
    unawaited(_player.play());
  }

  Future<void> play() async {
    if (!_isInitialized) await init();
    unawaited(_player.play());
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.stop();
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> skipToNext() async {
    final queueCtrl = CarMusicQueueController();
    if (queueCtrl.tracks.isNotEmpty) {
      final nextTrack = queueCtrl.getNextTrack();
      if (nextTrack != null) {
        await playQueueTrack(nextTrack);
      } else {
        await stop();
      }
      return;
    }

    _activeRemoteTrack = null;
    activeRemoteTrackNotifier.value = null;
    _selectedTrackIndex = (_selectedTrackIndex + 1) % tracks.length;
    if (_player.hasNext) {
      await _player.seekToNext();
    } else {
      await _player.seek(Duration.zero, index: 0);
    }
  }

  Future<void> skipToPrevious() async {
    final queueCtrl = CarMusicQueueController();
    if (queueCtrl.tracks.isNotEmpty) {
      final prevTrack = queueCtrl.getPreviousTrack();
      if (prevTrack != null) {
        await playQueueTrack(prevTrack);
      } else {
        await stop();
      }
      return;
    }

    _activeRemoteTrack = null;
    activeRemoteTrackNotifier.value = null;
    _selectedTrackIndex = (_selectedTrackIndex - 1 + tracks.length) % tracks.length;
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    } else {
      await _player.seek(Duration.zero, index: tracks.length - 1);
    }
  }


  Future<void> selectTrack(int index) async {
    _activeRemoteTrack = null;
    activeRemoteTrackNotifier.value = null;
    if (index >= 0 && index < tracks.length) {
      _selectedTrackIndex = index;
      await _player.seek(Duration.zero, index: index);
      unawaited(_player.play());
    }
  }

  String get currentLoopModeString {
    switch (_player.loopMode) {
      case LoopMode.off:
        return 'off';
      case LoopMode.one:
        return 'one';
      case LoopMode.all:
        return 'all';
    }
  }

  Future<void> setLoopModeString(String mode) async {
    final parsed = PlaybackMode.fromString(mode);
    CarMusicQueueController().setPlaybackMode(parsed);
    switch (mode.toLowerCase().trim()) {
      case 'one':
      case 'single':
        await _player.setLoopMode(LoopMode.one);
        break;
      case 'off':
      case 'none':
        await _player.setLoopMode(LoopMode.off);
        break;
      case 'all':
      default:
        await _player.setLoopMode(LoopMode.all);
        break;
    }
  }

  Future<void> cycleLoopMode() async {
    final current = _player.loopMode;
    switch (current) {
      case LoopMode.off:
        await setLoopModeString('all');
        break;
      case LoopMode.all:
        await setLoopModeString('one');
        break;
      case LoopMode.one:
        await setLoopModeString('off');
        break;
    }
  }

  Future<void> setShuffle(bool enabled) async {
    if (enabled) {
      CarMusicQueueController().setPlaybackMode(PlaybackMode.shuffle);
    } else {
      CarMusicQueueController().setPlaybackMode(PlaybackMode.listLoop);
    }
    await _player.setShuffleModeEnabled(enabled);
  }

  Future<void> toggleShuffle() async {
    final enabled = _player.shuffleModeEnabled;
    await setShuffle(!enabled);
  }


  Future<void> setVolume(double val) async {
    _currentVolume = val.clamp(0.0, 1.0);
    await _player.setVolume(_currentVolume);
  }

  /// Safe temporary low-volume playback (runs for specified duration and auto-pauses)
  Future<void> testShortPlayback({Duration duration = const Duration(seconds: 3)}) async {
    if (!_isInitialized) await init();
    await _player.setVolume(0.20); // 20% safe low volume
    await _player.play();
    Timer(duration, () async {
      try {
        await _player.pause();
      } catch (_) {}
    });
  }

  Future<void> dispose() async {
    await _player.dispose();
    _isInitialized = false;
  }
}
