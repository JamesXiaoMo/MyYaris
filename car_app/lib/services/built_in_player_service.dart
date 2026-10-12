import 'dart:async';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

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

  LocalTrackItem get currentTrack {
    if (_activeRemoteTrack != null) return _activeRemoteTrack!;
    final idx = _player.currentIndex ?? 0;
    if (idx >= 0 && idx < tracks.length) {
      return tracks[idx];
    }
    return tracks[0];
  }

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      // 1. Configure audio session for car audio focus & ducking
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

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

      _isInitialized = true;
      debugPrint('[BuiltInPlayer] Initialized successfully with ${tracks.length} tracks.');
    } catch (e) {
      debugPrint('[BuiltInPlayer] Initialization error: $e');
      rethrow;
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

    final uri = Uri.parse(streamUrl);
    final source = AudioSource.uri(uri, headers: headers);
    await _player.setAudioSource(source, initialPosition: initialPosition ?? Duration.zero);
    await _player.play();
  }

  Future<void> play() async {
    if (!_isInitialized) await init();
    await _player.play();
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
    _activeRemoteTrack = null;
    if (_player.hasNext) {
      await _player.seekToNext();
    } else {
      await _player.seek(Duration.zero, index: 0);
    }
  }

  Future<void> skipToPrevious() async {
    _activeRemoteTrack = null;
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    } else {
      await _player.seek(Duration.zero, index: tracks.length - 1);
    }
  }

  Future<void> selectTrack(int index) async {
    _activeRemoteTrack = null;
    if (index >= 0 && index < tracks.length) {
      await _player.seek(Duration.zero, index: index);
      await _player.play();
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
    switch (mode.toLowerCase().trim()) {
      case 'one':
        await _player.setLoopMode(LoopMode.one);
        break;
      case 'off':
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
        await _player.setLoopMode(LoopMode.all);
        break;
      case LoopMode.all:
        await _player.setLoopMode(LoopMode.one);
        break;
      case LoopMode.one:
        await _player.setLoopMode(LoopMode.off);
        break;
    }
  }

  Future<void> setShuffle(bool enabled) async {
    await _player.setShuffleModeEnabled(enabled);
  }

  Future<void> toggleShuffle() async {
    final enabled = _player.shuffleModeEnabled;
    await _player.setShuffleModeEnabled(!enabled);
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
