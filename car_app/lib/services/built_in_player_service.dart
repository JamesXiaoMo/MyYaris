import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'in_app_audio_stream_proxy.dart';
import 'car_music_queue_controller.dart';
import 'car_music_sync_service.dart';
import 'music_cache_service.dart';
import '../models/music_queue_models.dart';

class LocalTrackItem {
  final String id;
  final String title;
  final String artist;
  final String assetPath;
  final bool isLocal;
  final String durationDesc;
  final String tag;
  final String? coverUrl;

  const LocalTrackItem({
    required this.id,
    required this.title,
    required this.artist,
    required this.assetPath,
    required this.isLocal,
    required this.durationDesc,
    required this.tag,
    this.coverUrl,
  });
}

class BuiltInPlayerService {
  static final BuiltInPlayerService _instance = BuiltInPlayerService._internal();
  factory BuiltInPlayerService() => _instance;
  BuiltInPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();
  AudioPlayer get player => _player;
  AudioPlayer? _sfxPlayer;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  static const String _savedVolumeKey = 'myyaris_saved_music_volume';
  static const String _savedAiVoiceVolumeKey = 'myyaris_saved_ai_voice_volume';
  static const String _savedLastTrackKey = 'myyaris_saved_last_track_v1';

  NeteaseQueueTrackItem? _savedLastTrack;
  NeteaseQueueTrackItem? get savedLastTrack => _savedLastTrack;
  int _savedLastPositionMs = 0;
  int get savedLastPositionMs => _savedLastPositionMs;

  // Safe initial low volume to prevent blasting car speakers
  double _currentVolume = 0.25;
  double get currentVolume => _currentVolume;
  double _aiVoiceVolume = 0.95;
  double get aiVoiceVolume => _aiVoiceVolume;
  final ValueNotifier<double> aiVoiceVolumeNotifier = ValueNotifier<double>(0.95);
  bool _voiceDuckActive = false;
  bool _osFocusDucked = false;
  Future<void> _voiceReplyTail = Future.value();

  Future<void> _applyMusicVolume() async {
    final double target;
    if (_voiceDuckActive) {
      target = (_currentVolume * 0.20).clamp(0.03, 0.25);
    } else if (_osFocusDucked) {
      target = (_currentVolume * 0.50).clamp(0.05, 1.0);
    } else {
      target = _currentVolume;
    }
    try {
      await _player.setVolume(target);
    } catch (_) {}
  }

  /// Ensures Android AudioFocus / CarPlay media audio bridge is active and volume is applied
  /// before starting playback (fixes silent music on cold boot until AI TTS wakes the HAL).
  Future<void> _ensureAudioSessionActive() async {
    _osFocusDucked = false;
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (_) {}
    await _applyMusicVolume();
  }

  /// Best-known duration of the current track: prefers ExoPlayer's parsed duration,
  /// falling back to Netease queue metadata so streaming tracks never stick at 100%.
  Duration get effectiveDuration {
    final playerDur = _player.duration;
    if (playerDur != null && playerDur.inMilliseconds > 0) {
      return playerDur;
    }
    final metaMs = CarMusicQueueController().currentTrack?.durationMs ??
        _savedLastTrack?.durationMs ??
        0;
    if (metaMs > 0) {
      return Duration(milliseconds: metaMs);
    }
    return Duration.zero;
  }

  Future<void> setAiVoiceVolume(double value) async {
    final clamped = value.clamp(0.1, 1.0);
    _aiVoiceVolume = clamped;
    aiVoiceVolumeNotifier.value = clamped;
    try {
      await _sfxPlayer?.setVolume(clamped);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_savedAiVoiceVolumeKey, clamped);
    } catch (_) {}
  }

  List<LocalTrackItem> get tracks => CarMusicQueueController().tracks.map((t) => LocalTrackItem(
    id: t.trackId, title: t.title, artist: t.artist, assetPath: t.streamUrl,
    isLocal: false, durationDesc: '${t.durationMs ~/ 1000}秒', tag: '网易云', coverUrl: t.coverUrl)).toList();

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
        coverUrl: queueTrack.coverUrl,
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
              debugPrint('[BuiltInPlayer] Audio focus ducking');
              _osFocusDucked = true;
              unawaited(_applyMusicVolume());
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
              debugPrint('[BuiltInPlayer] Audio focus unduck');
              _osFocusDucked = false;
              unawaited(_applyMusicVolume());
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

      try {
        final prefs = await SharedPreferences.getInstance();
        final saved = prefs.getDouble(_savedVolumeKey);
        if (saved != null && saved >= 0.05 && saved <= 1.0) {
          _currentVolume = saved;
        }
        final savedAi = prefs.getDouble(_savedAiVoiceVolumeKey);
        if (savedAi != null && savedAi >= 0.1 && savedAi <= 1.0) {
          _aiVoiceVolume = savedAi;
          aiVoiceVolumeNotifier.value = savedAi;
        }
        final rawLast = prefs.getString(_savedLastTrackKey);
        if (rawLast != null && rawLast.isNotEmpty) {
          final decoded = jsonDecode(rawLast);
          if (decoded is Map<String, dynamic>) {
            final item = NeteaseQueueTrackItem.fromJson(decoded);
            if (item.songId > 0 && item.title.isNotEmpty) {
              _savedLastTrack = item;
              _savedLastPositionMs = (decoded['position_ms'] as num?)?.toInt() ?? 0;
              _activeRemoteTrack ??= LocalTrackItem(
                id: item.trackId,
                title: item.title,
                artist: item.artist,
                assetPath: item.streamUrl,
                isLocal: false,
                durationDesc: '${item.durationMs ~/ 1000}秒',
                tag: item.album ?? '网络歌单',
              );
              activeRemoteTrackNotifier.value = _activeRemoteTrack;
            }
          }
        }
      } catch (_) {}

      await _player.setVolume(_currentVolume);
      await _player.setLoopMode(LoopMode.off);
      await _player.setShuffleModeEnabled(false);

      // 3. Start in-app loopback proxy & init SD-card music cache BEFORE restoring last queue
      try {
        await InAppAudioStreamProxy().start();
      } catch (e) {
        debugPrint('[BuiltInPlayer] InAppAudioStreamProxy start note: $e');
      }
      await MusicCacheService().init();
      final restoredQueue = await CarMusicQueueController().restoreLastQueueFromDisk();
      if (restoredQueue && _activeRemoteTrack == null) {
        final cur = CarMusicQueueController().currentTrack;
        if (cur != null) {
          final isCached = MusicCacheService().getCachedFile(cur.songId) != null;
          _savedLastTrack ??= cur;
          _activeRemoteTrack = LocalTrackItem(
            id: cur.trackId,
            title: cur.title,
            artist: cur.artist,
            assetPath: cur.streamUrl,
            isLocal: isCached,
            durationDesc: '${cur.durationMs ~/ 1000}秒${isCached ? " • 本地 SD 缓存" : ""}',
            tag: isCached ? 'SD 离线' : (cur.album ?? '网络歌单'),
            coverUrl: cur.coverUrl,
          );
          activeRemoteTrackNotifier.value = _activeRemoteTrack;
        }
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
      final online = CarMusicSyncService().isHealthyNotifier.value;
      final nextTrack = online
          ? await queueCtrl.nextTrackForPlayback()
          : (queueCtrl.getNextCachedTrack() ?? await queueCtrl.nextTrackForPlayback());
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
          // Before giving up offline, try jumping directly to a locally cached track
          final cachedFallback = ctrl.getNextCachedTrack();
          if (cachedFallback != null) {
            try {
              await playQueueTrack(cachedFallback, rethrowOnError: true);
              return;
            } catch (_) {}
          }
          await stop();
          return;
        }
        final online = CarMusicSyncService().isHealthyNotifier.value;
        final next = online
            ? await ctrl.nextTrackForPlayback()
            : (ctrl.getNextCachedTrack() ?? await ctrl.nextTrackForPlayback());
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

      // Check local SD-card cache FIRST for instant (<50ms) zero-network playback!
      final cachedFile = MusicCacheService().getCachedFile(track.songId);
      final bool playedFromCache = cachedFile != null;
      String fullStreamUrl = track.streamUrl;
      final token = headers?['X-Device-Token'] ??
          headers?['Authorization']?.replaceAll('Bearer ', '') ??
          _currentDeviceToken;

      final AudioSource source;
      if (playedFromCache) {
        source = AudioSource.file(cachedFile.path);
        debugPrint('[BuiltInPlayer] Playing song ${track.songId} from local SD cache (0 data)');
      } else {
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
        final resolvedUrl = InAppAudioStreamProxy().resolveStreamUrl(
          fullStreamUrl,
          token: token,
        );
        final uri = Uri.parse(resolvedUrl);
        source = AudioSource.uri(uri, headers: headers);
      }

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
        assetPath: playedFromCache ? cachedFile.path : track.streamUrl,
        isLocal: playedFromCache,
        durationDesc: '${track.durationMs ~/ 1000}秒 • ${playedFromCache ? "本地 SD 缓存" : "在线流"}',
        tag: playedFromCache ? 'SD 离线' : (track.album ?? '网络歌单'),
        coverUrl: track.coverUrl,
      );
      if (!playedFromCache) {
        unawaited(_prefetchNextTrackOnBackend());
      }
      activeRemoteTrackNotifier.value = _activeRemoteTrack;
      _savedLastTrack = track;
      _savedLastPositionMs = (initialPosition ?? Duration.zero).inMilliseconds;
      unawaited(_persistLastTrack(track, _savedLastPositionMs));
      unawaited(CarMusicQueueController().persistActiveQueueToDisk());

      if (startPlaying) {
        await _ensureAudioSessionActive();
        unawaited(_player.play().catchError((Object _) {}));
        if (!playedFromCache) {
          MusicCacheService().cacheInBackgroundIfEnabled(
            songId: track.songId,
            fullStreamUrl: fullStreamUrl,
            token: token,
          );
        }
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

  Future<void> _persistLastTrack(NeteaseQueueTrackItem track, int positionMs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _savedLastTrackKey,
        jsonEncode({
          'song_id': track.songId,
          'track_id': track.trackId,
          'title': track.title,
          'artist': track.artist,
          'album': track.album,
          'duration_ms': track.durationMs,
          'stream_url': track.streamUrl,
          'playable': track.playable,
          'position_ms': positionMs < 0 ? 0 : positionMs,
        }),
      );
    } catch (_) {}
  }

  Future<void> _prefetchNextTrackOnBackend() async {
    if (_currentBaseUrl.isEmpty || _currentDeviceToken.isEmpty) return;
    final ctrl = CarMusicQueueController();
    final tracks = ctrl.tracks;
    if (tracks.length < 2) return;
    final nextIdx = (ctrl.currentIndex + 1) % tracks.length;
    final nextTrack = tracks[nextIdx];
    if (nextTrack.songId <= 0) return;
    try {
      final uri = Uri.parse('$_currentBaseUrl/api/v1/music/netease/prefetch/${nextTrack.songId}');
      final req = await HttpClient().postUrl(uri).timeout(const Duration(seconds: 4));
      req.headers.set('Authorization', 'Bearer $_currentDeviceToken');
      req.headers.set('X-Device-Token', _currentDeviceToken);
      final res = await req.close().timeout(const Duration(seconds: 4));
      await res.drain<void>();
    } catch (_) {}
  }

  /// Plays a short DJ sound effect overlaid on top of current music (briefly ducking volume).
  Future<void> playSoundEffect(String sfxUrl) async {
    if (sfxUrl.trim().isEmpty) return;
    try {
      String fullUrl = sfxUrl.trim();
      if (fullUrl.startsWith('/') && _currentBaseUrl.isNotEmpty) {
        fullUrl = '$_currentBaseUrl$fullUrl';
      }
      final resolved = InAppAudioStreamProxy().resolveStreamUrl(
        fullUrl,
        token: _currentDeviceToken,
      );
      _sfxPlayer ??= AudioPlayer();
      final prevVol = _currentVolume;
      final duckVol = (prevVol * 0.45).clamp(0.05, 1.0);
      if (_player.playing) {
        await _player.setVolume(duckVol);
      }
      await _sfxPlayer!.setVolume((prevVol * 1.35).clamp(0.35, 1.0));
      await _sfxPlayer!.setAudioSource(AudioSource.uri(Uri.parse(resolved)));
      await _sfxPlayer!.play();
      // Restore music volume smoothly after the short effect
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 1800), () async {
          try {
            await _player.setVolume(_currentVolume);
          } catch (_) {}
        }),
      );
    } catch (e) {
      debugPrint('[BuiltInPlayer] SFX playback note: $e');
    }
  }

  /// Ducks music volume sharply while the driver is speaking to the AI assistant.
  Future<void> duckForVoiceInput() async {
    _voiceDuckActive = true;
    await _applyMusicVolume();
  }

  /// Restores music volume back to the user's configured level.
  Future<void> restoreMusicVolume() async {
    _voiceDuckActive = false;
    await _applyMusicVolume();
  }

  /// Plays a Chinese AI TTS voice response over ducked music, then restores volume.
  /// Returns true only when cloud audio loaded and played cleanly; false triggers offline TTS fallback.
  Future<bool> playVoiceReply(
    String ttsUrl, {
    String? baseUrl,
    String? token,
  }) async {
    final completer = Completer<bool>();
    final prev = _voiceReplyTail;
    _voiceReplyTail = completer.future.then((_) {}, onError: (_) {});
    await prev;
    try {
      final ok = await _playVoiceReplyInternal(
        ttsUrl,
        baseUrl: baseUrl,
        token: token,
      );
      completer.complete(ok);
      return ok;
    } catch (e) {
      completer.complete(false);
      return false;
    }
  }

  Future<bool> _playVoiceReplyInternal(
    String ttsUrl, {
    String? baseUrl,
    String? token,
  }) async {
    if (ttsUrl.trim().isEmpty) {
      await restoreMusicVolume();
      return false;
    }
    try {
      var effectiveBase = (baseUrl ?? _currentBaseUrl).trim();
      while (effectiveBase.endsWith('/')) {
        effectiveBase = effectiveBase.substring(0, effectiveBase.length - 1);
      }
      final effectiveToken = (token != null && token.trim().isNotEmpty)
          ? token.trim()
          : _currentDeviceToken;

      String fullUrl = ttsUrl.trim();
      if (fullUrl.startsWith('/')) {
        if (effectiveBase.isEmpty) {
          debugPrint('[BuiltInPlayer] Voice reply skipped: missing baseUrl for relative TTS URL');
          return false;
        }
        fullUrl = '$effectiveBase$fullUrl';
      }
      final resolved = InAppAudioStreamProxy().resolveStreamUrl(
        fullUrl,
        token: effectiveToken,
      );

      // Disable AudioSession interruption handling on _sfxPlayer so it NEVER fights
      // _player for audio focus or gets ducked to 50% by CAR NAVITIME / Android focus events.
      _sfxPlayer ??= AudioPlayer(
        handleInterruptions: false,
        androidApplyAudioAttributes: false,
      );

      _voiceDuckActive = true;
      await _applyMusicVolume();

      // Always reset prior completed state before setting the new clip
      try {
        await _sfxPlayer!.stop();
      } catch (_) {}

      await _sfxPlayer!.setVolume(_aiVoiceVolume);
      final duration = await _sfxPlayer!
          .setAudioSource(AudioSource.uri(Uri.parse(resolved)), preload: true)
          .timeout(const Duration(seconds: 6));

      final waitSec = duration != null && duration.inSeconds > 0
          ? (duration.inSeconds + 5).clamp(6, 25)
          : 15;
      var timedOut = false;
      final done = _sfxPlayer!.playerStateStream
          .firstWhere((s) => s.processingState == ProcessingState.completed)
          .timeout(Duration(seconds: waitSec), onTimeout: () {
            timedOut = true;
            return _sfxPlayer!.playerState;
          });
      await _sfxPlayer!.setVolume(_aiVoiceVolume);
      unawaited(_sfxPlayer!.play().catchError((Object _) {}));
      await done;
      if (timedOut) {
        try {
          await _sfxPlayer!.stop();
        } catch (_) {}
      }
      return !timedOut;
    } catch (e) {
      debugPrint('[BuiltInPlayer] Voice reply playback note: $e');
      return false;
    } finally {
      await restoreMusicVolume();
    }
  }

  Future<void> play() async {
    if (!_isInitialized) await init();
    if (_activeRemoteTrack == null) throw StateError('请显式选择默认喜欢歌单播放');
    if (_player.audioSource == null && _savedLastTrack != null) {
      await playQueueTrack(
        _savedLastTrack!,
        initialPosition: Duration(milliseconds: _savedLastPositionMs),
        startPlaying: true,
      );
      return;
    }
    _stopped = false;
    await _ensureAudioSessionActive();
    unawaited(_player.play().catchError((Object _) {}));
  }

  Future<void> pause() async {
    _resumeAfterInterruption = false;
    await _player.pause();
    if (_savedLastTrack != null) {
      _savedLastPositionMs = _player.position.inMilliseconds;
      unawaited(_persistLastTrack(_savedLastTrack!, _savedLastPositionMs));
    }
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
    await _applyMusicVolume();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_savedVolumeKey, _currentVolume);
    } catch (_) {}
  }

  /// Immediately caches the currently active Netease track to SD card (even if cache-on-play is off).
  Future<bool> cacheCurrentTrackNow({
    required String baseUrl,
    required String token,
  }) async {
    final queueTrack = CarMusicQueueController().currentTrack ?? _savedLastTrack;
    int songId = queueTrack?.songId ?? 0;
    String streamUrl = queueTrack?.streamUrl ?? '';
    if (songId <= 0) {
      final match = RegExp(r'(\d+)').firstMatch(currentTrack.id);
      if (match != null) {
        songId = int.tryParse(match.group(1)!) ?? 0;
      }
    }
    if (songId <= 0) return false;
    var effectiveBase = baseUrl.trim();
    while (effectiveBase.endsWith('/')) {
      effectiveBase = effectiveBase.substring(0, effectiveBase.length - 1);
    }
    if (streamUrl.isEmpty) {
      streamUrl = '/api/v1/music/netease/stream/$songId';
    }
    if (streamUrl.startsWith('/')) {
      if (effectiveBase.isEmpty) return false;
      streamUrl = '$effectiveBase$streamUrl';
    }
    return MusicCacheService().downloadTrack(
      songId: songId,
      fullStreamUrl: streamUrl,
      token: token.trim(),
    );
  }

  Future<void> dispose() async {
    await _player.dispose();
    _isInitialized = false;
  }
}
