import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'built_in_player_service.dart';
import 'car_music_sync_service.dart';
import 'car_music_queue_controller.dart';

/// System MediaSession & Notification AudioHandler implementation for MyYaris.
/// Bridges BuiltInPlayerService (just_audio) to Android MediaSession,
/// supporting lockscreen controls, notification controls, and audio focus transitions.
class CarAudioHandler extends BaseAudioHandler with SeekHandler {
  final BuiltInPlayerService _playerService = BuiltInPlayerService();

  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _playbackEventSubscription;
  StreamSubscription? _sequenceStateSubscription;

  CarAudioHandler() {
    _initStreams();
  }

  void _initStreams() {
    // 1. Sync playback state from just_audio player
    _playerStateSubscription = _playerService.player.playerStateStream.listen((_) {
      _broadcastPlaybackState();
    });

    _playbackEventSubscription = _playerService.player.playbackEventStream.listen((_) {
      _broadcastPlaybackState();
    });

    // 2. Sync track / sequence metadata
    _sequenceStateSubscription = _playerService.player.sequenceStateStream.listen((_) {
      _broadcastMediaItem();
    });
    _playerService.activeRemoteTrackNotifier.addListener(_broadcastMediaItem);

    // Initial sync
    _broadcastMediaItem();
    _broadcastPlaybackState();
  }

  /// Broadcasts current track metadata to MediaSession and Notification
  void broadcastCurrentTrack() {
    _broadcastMediaItem();
    _broadcastPlaybackState();
  }

  void _broadcastMediaItem() {
    final track = _playerService.currentTrack;
    final duration = _playerService.player.duration;

    mediaItem.add(MediaItem(
      id: track.id,
      album: track.tag,
      title: track.title,
      artist: track.artist,
      duration: duration,
    ));
  }

  void _broadcastPlaybackState() {
    final player = _playerService.player;
    final isPlaying = player.playing;
    final processingState = player.processingState;

    AudioProcessingState audioProcessingState;
    switch (processingState) {
      case ProcessingState.idle:
        audioProcessingState = AudioProcessingState.idle;
        break;
      case ProcessingState.loading:
        audioProcessingState = AudioProcessingState.loading;
        break;
      case ProcessingState.buffering:
        audioProcessingState = AudioProcessingState.buffering;
        break;
      case ProcessingState.ready:
        audioProcessingState = AudioProcessingState.ready;
        break;
      case ProcessingState.completed:
        audioProcessingState = AudioProcessingState.completed;
        break;
    }

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (isPlaying) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
        MediaAction.setRepeatMode,
        MediaAction.setShuffleMode,
      },
      androidCompactActionIndices: const [0, 1, 3],
      processingState: audioProcessingState,
      playing: isPlaying,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      speed: player.speed,
      queueIndex: CarMusicQueueController().currentIndex,
    ));
  }

  @override
  Future<void> play() => CarMusicSyncService().requestLocalCommand('resume');

  @override
  Future<void> pause() => CarMusicSyncService().requestLocalCommand('pause');

  @override
  Future<void> stop() => CarMusicSyncService().requestLocalCommand('stop');

  @override
  Future<void> seek(Duration position) => CarMusicSyncService().requestLocalCommand('seek', {'position_ms': position.inMilliseconds});

  @override
  Future<void> skipToNext() => CarMusicSyncService().requestLocalCommand('next');

  @override
  Future<void> skipToPrevious() => CarMusicSyncService().requestLocalCommand('prev');

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await CarMusicSyncService().requestLocalCommand('set_playback_mode', {
      'mode': repeatMode == AudioServiceRepeatMode.one ? 'single_loop' : 'list_loop',
    });
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
    CarMusicSyncService().requestLocalCommand('set_playback_mode', {
      'mode': shuffleMode == AudioServiceShuffleMode.all || shuffleMode == AudioServiceShuffleMode.group ? 'shuffle' : 'list_loop',
    });

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    debugPrint('[CarAudioHandler] customAction: $name extras: $extras');
    if (name == 'setVolume' && extras != null && extras['volume'] is num) {
      await _playerService.setVolume((extras['volume'] as num).toDouble());
    }
  }

  Future<void> dispose() async {
    await _playerStateSubscription?.cancel();
    await _playbackEventSubscription?.cancel();
    await _sequenceStateSubscription?.cancel();
  }
}
