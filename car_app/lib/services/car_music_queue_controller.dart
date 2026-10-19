import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/music_queue_models.dart';
import 'backend_client.dart';

enum CircuitBreakerAction {
  skipToNext,
  stopPlayer,
}

/// Central controller for Car Music Queue and Playback Mode scheduling (V2.2.0 contract).
/// Maintains full-queue in-memory snapshot, autonomous progression, Fisher-Yates shuffle,
/// authentic intelligence streaming, and 3-failure circuit breaking.
class CarMusicQueueController {
  static final CarMusicQueueController _instance = CarMusicQueueController._internal();
  factory CarMusicQueueController() => _instance;
  CarMusicQueueController._internal();

  BackendClient? _backendClient;
  String _baseUrl = '';
  String _token = '';
  String _deviceId = 'car_p3pro';

  // Queue metadata snapshot
  String _queueId = '';
  String get queueId => _queueId;

  int _queueVersion = 0;
  int get queueVersion => _queueVersion;

  String _queueSource = QueueSource.neteaseFavorite;
  String get queueSource => _queueSource;

  String? _queueName;
  String? get queueName => _queueName;

  int _total = 0;
  int get total => _total;

  bool _isComplete = false;
  bool get isComplete => _isComplete;

  bool _isFullyLoaded = false;
  bool get isFullyLoaded => _isFullyLoaded;

  // In-memory track list for the active queue
  final List<NeteaseQueueTrackItem> _tracks = [];
  List<NeteaseQueueTrackItem> get tracks => List.unmodifiable(_tracks);

  // Current playing index in _tracks
  int _currentIndex = 0;
  int get currentIndex => _currentIndex;

  NeteaseQueueTrackItem? get currentTrack {
    if (_tracks.isEmpty) return null;
    if (_currentIndex >= 0 && _currentIndex < _tracks.length) {
      return _tracks[_currentIndex];
    }
    return _tracks[0];
  }

  // Playback modes
  PlaybackMode _appliedMode = PlaybackMode.listLoop;
  PlaybackMode get appliedMode => _appliedMode;

  PlaybackMode _requestedMode = PlaybackMode.listLoop;
  PlaybackMode get requestedMode => _requestedMode;

  // Shuffle order permutation (contains track indices into _tracks)
  List<int> _shuffleIndices = [];
  List<int> get shuffleIndices => List.unmodifiable(_shuffleIndices);
  int _shufflePosition = 0;
  int get shufflePosition => _shufflePosition;

  // Consecutive failures circuit breaker
  int _consecutiveFailures = 0;
  int get consecutiveFailures => _consecutiveFailures;
  static const int maxConsecutiveFailures = 3;

  String? _errorCode;
  String? get errorCode => _errorCode;

  String? _errorDetail;
  String? get errorDetail => _errorDetail;

  // Memory backup of favorite queue context when temporarily entering single_track
  String _previousFavoriteQueueId = '';
  int _previousFavoriteQueueVersion = 0;
  int _previousFavoriteIndex = 0;
  List<NeteaseQueueTrackItem> _previousFavoriteTracks = [];
  int _previousFavoriteTotal = 0;
  bool _previousFavoriteComplete = false;

  // Intelligence continuation state
  int _intelligenceBatchIndex = 0;
  int get intelligenceBatchIndex => _intelligenceBatchIndex;
  int? _intelligencePlaylistId;
  bool _isContinuingIntelligence = false;
  static const int maxIntelligenceBatches = 5;

  // Notifier for UI/Service bindings
  final ValueNotifier<int> queueVersionNotifier = ValueNotifier(0);
  final ValueNotifier<NeteaseQueueTrackItem?> currentTrackNotifier = ValueNotifier(null);
  final ValueNotifier<PlaybackMode> appliedModeNotifier = ValueNotifier(PlaybackMode.listLoop);

  void configure({
    required String baseUrl,
    required String token,
    String deviceId = 'car_p3pro',
    BackendClient? backendClient,
  }) {
    _baseUrl = baseUrl.trim();
    while (_baseUrl.endsWith('/')) {
      _baseUrl = _baseUrl.substring(0, _baseUrl.length - 1);
    }
    _token = token.trim();
    _deviceId = deviceId.trim();
    _backendClient = backendClient ?? BackendClient();
  }

  /// Sets queue snapshot directly (useful for tests or received snapshot payload)
  void setQueueSnapshot(MusicQueueSnapshot snapshot, {int startIndex = 0}) {
    _queueId = snapshot.queueId;
    _queueVersion = snapshot.queueVersion;
    _queueSource = snapshot.source;
    _queueName = snapshot.name;
    _total = snapshot.total;
    _isComplete = snapshot.isComplete;

    _tracks.clear();
    _tracks.addAll(snapshot.tracks);
    _isFullyLoaded = snapshot.isComplete && (_tracks.length >= snapshot.total);

    if (startIndex >= 0 && startIndex < _tracks.length) {
      _currentIndex = startIndex;
    } else {
      _currentIndex = 0;
    }

    _consecutiveFailures = 0;
    _errorCode = null;
    _errorDetail = null;

    if (_appliedMode == PlaybackMode.shuffle && _isFullyLoaded && _tracks.isNotEmpty) {
      _generateShuffleOrder(seedIndex: _currentIndex);
    }

    queueVersionNotifier.value = _queueVersion;
    currentTrackNotifier.value = currentTrack;
  }

  /// Appends tracks from next page (checking snapshot version match)
  bool appendPage(MusicQueueSnapshot page) {
    if (_queueId.isNotEmpty && page.queueId != _queueId) {
      debugPrint('[CarMusicQueue] Page queueId mismatch: got ${page.queueId}, expected $_queueId');
      return false;
    }
    if (_queueVersion > 0 && page.queueVersion != _queueVersion) {
      debugPrint('[CarMusicQueue] Page queueVersion mismatch: got ${page.queueVersion}, expected $_queueVersion');
      return false;
    }

    _queueId = page.queueId;
    _queueVersion = page.queueVersion;
    _total = page.total;
    _isComplete = page.isComplete;

    for (final track in page.tracks) {
      if (!_tracks.any((t) => t.trackId == track.trackId)) {
        _tracks.add(track);
      }
    }

    _isFullyLoaded = _isComplete && (_tracks.length >= _total);

    if (_appliedMode == PlaybackMode.shuffle && _isFullyLoaded && _shuffleIndices.isEmpty) {
      _generateShuffleOrder(seedIndex: _currentIndex);
    }

    queueVersionNotifier.value = _queueVersion;
    currentTrackNotifier.value = currentTrack;
    return true;
  }

  /// Fetches the full favorite playlist across pages with version locking and bounded retry.
  Future<bool> loadFullFavoriteQueue({int maxRetries = 3}) async {
    if (_backendClient == null || _baseUrl.isEmpty) {
      debugPrint('[CarMusicQueue] Cannot load queue: BackendClient or baseUrl not configured');
      return false;
    }

    int retryCount = 0;
    while (retryCount < maxRetries) {
      try {
        debugPrint('[CarMusicQueue] Fetching favorite queue page 0 (attempt ${retryCount + 1})...');
        final firstPage = await _backendClient!.fetchMusicQueuePage(
          baseUrl: _baseUrl,
          token: _token,
          deviceId: _deviceId,
          source: QueueSource.neteaseFavorite,
          offset: 0,
          limit: 50,
        );

        _queueId = firstPage.queueId;
        _queueVersion = firstPage.queueVersion;
        _queueSource = QueueSource.neteaseFavorite;
        _queueName = firstPage.name ?? '我喜欢的音乐';
        _total = firstPage.total;
        _isComplete = firstPage.isComplete;

        _tracks.clear();
        _tracks.addAll(firstPage.tracks);

        // Fetch subsequent pages with locked queue_id and queue_version
        while (_tracks.length < _total && firstPage.hasMore) {
          final nextOffset = _tracks.length;
          debugPrint('[CarMusicQueue] Fetching page at offset $nextOffset (v$_queueVersion)...');
          final nextPage = await _backendClient!.fetchMusicQueuePage(
            baseUrl: _baseUrl,
            token: _token,
            deviceId: _deviceId,
            source: QueueSource.neteaseFavorite,
            offset: nextOffset,
            limit: 50,
            queueId: _queueId,
            queueVersion: _queueVersion,
          );

          if (nextPage.queueVersion != _queueVersion) {
            throw BackendException(409, 'Queue version shifted during paging: expected $_queueVersion, got ${nextPage.queueVersion}');
          }

          _tracks.addAll(nextPage.tracks);
          if (!nextPage.hasMore || nextPage.tracks.isEmpty) break;
        }

        _isFullyLoaded = true;
        if (_currentIndex >= _tracks.length) {
          _currentIndex = 0;
        }

        if (_appliedMode == PlaybackMode.shuffle) {
          _generateShuffleOrder(seedIndex: _currentIndex);
        }

        queueVersionNotifier.value = _queueVersion;
        currentTrackNotifier.value = currentTrack;
        debugPrint('[CarMusicQueue] Full favorite queue loaded successfully: ${_tracks.length}/$_total tracks (v$_queueVersion).');
        return true;
      } on BackendException catch (e) {
        debugPrint('[CarMusicQueue] BackendException loading queue: ${e.statusCode} ${e.message}');
        if (e.statusCode == 409) {
          // Version conflict or queue not ready: discard and retry from offset 0
          retryCount++;
          await Future.delayed(Duration(milliseconds: 500 * retryCount));
          continue;
        }
        _errorCode = 'LOAD_QUEUE_FAILED';
        _errorDetail = e.message;
        return false;
      } catch (e) {
        debugPrint('[CarMusicQueue] Unexpected error loading queue: $e');
        retryCount++;
        await Future.delayed(Duration(milliseconds: 500 * retryCount));
      }
    }

    _errorCode = 'LOAD_QUEUE_RETRIES_EXCEEDED';
    _errorDetail = '拉取喜欢歌单连续 $maxRetries 次失败';
    return false;
  }

  /// Generates a complete Fisher-Yates shuffle permutation of 0..total-1.
  /// Ensures seedIndex (current playing track) is at position 0 without repetition.
  void _generateShuffleOrder({int seedIndex = 0}) {
    if (_tracks.isEmpty) {
      _shuffleIndices = [];
      _shufflePosition = 0;
      return;
    }

    final n = _tracks.length;
    final validSeed = (seedIndex >= 0 && seedIndex < n) ? seedIndex : 0;

    // Remaining items to shuffle
    final rest = <int>[];
    for (int i = 0; i < n; i++) {
      if (i != validSeed) rest.add(i);
    }

    // Standard Fisher-Yates shuffle
    final rng = math.Random();
    for (int i = rest.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final temp = rest[i];
      rest[i] = rest[j];
      rest[j] = temp;
    }

    _shuffleIndices = [validSeed, ...rest];
    _shufflePosition = 0;
    debugPrint('[CarMusicQueue] Generated Fisher-Yates shuffle order (${_shuffleIndices.length} tracks, seed=$validSeed)');
  }

  /// Sets requested mode and applies if requirements are met.
  /// Preserves playing/paused status (does not start or pause audio engine).
  bool setPlaybackMode(PlaybackMode mode, {int? seedSongId}) {
    _requestedMode = mode;

    switch (mode) {
      case PlaybackMode.listLoop:
        _appliedMode = PlaybackMode.listLoop;
        appliedModeNotifier.value = _appliedMode;
        return true;

      case PlaybackMode.singleLoop:
        _appliedMode = PlaybackMode.singleLoop;
        appliedModeNotifier.value = _appliedMode;
        return true;

      case PlaybackMode.shuffle:
        if (!_isFullyLoaded || _tracks.isEmpty) {
          debugPrint('[CarMusicQueue] Cannot activate shuffle: queue not fully loaded (${_tracks.length}/$_total)');
          // Keep requestedMode = shuffle, but appliedMode remains listLoop until fully loaded
          _appliedMode = PlaybackMode.listLoop;
          appliedModeNotifier.value = _appliedMode;
          return false;
        }
        _generateShuffleOrder(seedIndex: _currentIndex);
        _appliedMode = PlaybackMode.shuffle;
        appliedModeNotifier.value = _appliedMode;
        return true;

      case PlaybackMode.intelligence:
        _appliedMode = PlaybackMode.intelligence;
        appliedModeNotifier.value = _appliedMode;
        return true;
    }
  }

  /// Switches queue source explicitly conforming to Section 1.2 / 4.4.
  void switchQueue({
    required String source,
    int startIndex = 0,
    String? startTrackId,
    NeteaseQueueTrackItem? singleTrackItem,
  }) {
    if (source == QueueSource.singleTrack) {
      if (singleTrackItem == null) {
        debugPrint('[CarMusicQueue] Cannot switch to single_track without track item');
        return;
      }
      // Backup current favorite queue context
      if (_queueSource == QueueSource.neteaseFavorite) {
        _previousFavoriteQueueId = _queueId;
        _previousFavoriteQueueVersion = _queueVersion;
        _previousFavoriteIndex = _currentIndex;
        _previousFavoriteTracks = List.from(_tracks);
        _previousFavoriteTotal = _total;
        _previousFavoriteComplete = _isComplete;
      }

      _queueSource = QueueSource.singleTrack;
      _queueId = 'q_single_${singleTrackItem.songId}_${DateTime.now().millisecondsSinceEpoch}';
      _queueVersion = 1;
      _total = 1;
      _isComplete = true;
      _isFullyLoaded = true;
      _tracks.clear();
      _tracks.add(singleTrackItem.copyWith(queueIndex: 0));
      _currentIndex = 0;
      _appliedMode = PlaybackMode.listLoop;

      queueVersionNotifier.value = _queueVersion;
      currentTrackNotifier.value = currentTrack;
      appliedModeNotifier.value = _appliedMode;
    } else if (source == QueueSource.neteaseFavorite) {
      // Restore favorite queue
      if (_previousFavoriteTracks.isNotEmpty) {
        _queueSource = QueueSource.neteaseFavorite;
        _queueId = _previousFavoriteQueueId;
        _queueVersion = _previousFavoriteQueueVersion;
        _tracks.clear();
        _tracks.addAll(_previousFavoriteTracks);
        _total = _previousFavoriteTotal;
        _isComplete = _previousFavoriteComplete;
        _isFullyLoaded = true;

        if (startTrackId != null && startTrackId.isNotEmpty) {
          final foundIdx = _tracks.indexWhere((t) => t.trackId == startTrackId);
          _currentIndex = foundIdx >= 0 ? foundIdx : _previousFavoriteIndex;
        } else {
          _currentIndex = _previousFavoriteIndex;
        }

        _appliedMode = _requestedMode == PlaybackMode.shuffle ? PlaybackMode.shuffle : PlaybackMode.listLoop;
        if (_appliedMode == PlaybackMode.shuffle) {
          _generateShuffleOrder(seedIndex: _currentIndex);
        }

        queueVersionNotifier.value = _queueVersion;
        currentTrackNotifier.value = currentTrack;
        appliedModeNotifier.value = _appliedMode;
      }
    }
  }

  /// Calculates next track based on appliedMode and queueSource.
  /// Returns null when single_track finishes or when intelligence queue is exhausted.
  NeteaseQueueTrackItem? getNextTrack() {
    if (_tracks.isEmpty) return null;

    // Single track mode: completion means STOP
    if (_queueSource == QueueSource.singleTrack) {
      debugPrint('[CarMusicQueue] Single track completed. Queue finished -> stopped.');
      return null;
    }

    if (_appliedMode == PlaybackMode.singleLoop) {
      return currentTrack;
    }

    if (_appliedMode == PlaybackMode.shuffle) {
      if (_shuffleIndices.isEmpty) {
        _generateShuffleOrder(seedIndex: _currentIndex);
      }

      _shufflePosition++;
      if (_shufflePosition >= _shuffleIndices.length) {
        // Complete shuffle loop finished, re-shuffle
        final lastIdx = _shuffleIndices.isNotEmpty ? _shuffleIndices.last : 0;
        _generateShuffleOrder(seedIndex: lastIdx);
        _shufflePosition = 0;
      }

      final nextIdx = _shuffleIndices[_shufflePosition];
      _currentIndex = nextIdx.clamp(0, _tracks.length - 1);
      currentTrackNotifier.value = currentTrack;
      return currentTrack;
    }

    if (_appliedMode == PlaybackMode.intelligence) {
      if (_currentIndex + 1 < _tracks.length) {
        _currentIndex++;
        currentTrackNotifier.value = currentTrack;

        // Dynamic streaming continuation trigger: less than 5 tracks remaining
        if (_currentIndex >= _tracks.length - 5 && !_isContinuingIntelligence) {
          unawaited(_continueIntelligenceBatch());
        }

        return currentTrack;
      } else {
        // Queue exhausted
        _errorCode = 'INTELLIGENCE_QUEUE_EXHAUSTED';
        _errorDetail = '心动模式推荐曲目已播完且续批失败';
        debugPrint('[CarMusicQueue] Intelligence queue exhausted. Playback stopped.');
        return null;
      }
    }

    // Default: listLoop
    _currentIndex = (_currentIndex + 1) % _tracks.length;
    currentTrackNotifier.value = currentTrack;
    return currentTrack;
  }

  /// Calculates previous track based on appliedMode.
  NeteaseQueueTrackItem? getPreviousTrack() {
    if (_tracks.isEmpty) return null;

    if (_queueSource == QueueSource.singleTrack) {
      return currentTrack;
    }

    if (_appliedMode == PlaybackMode.singleLoop) {
      return currentTrack;
    }

    if (_appliedMode == PlaybackMode.shuffle) {
      if (_shuffleIndices.isNotEmpty) {
        _shufflePosition = math.max(0, _shufflePosition - 1);
        final prevIdx = _shuffleIndices[_shufflePosition];
        _currentIndex = prevIdx.clamp(0, _tracks.length - 1);
        currentTrackNotifier.value = currentTrack;
        return currentTrack;
      }
    }

    // Default: listLoop
    _currentIndex = (_currentIndex - 1 + _tracks.length) % _tracks.length;
    currentTrackNotifier.value = currentTrack;
    return currentTrack;
  }

  /// Selects a track by trackId or index in the current active queue.
  bool selectTrackById(String trackId) {
    final idx = _tracks.indexWhere((t) => t.trackId == trackId);
    if (idx >= 0) {
      _currentIndex = idx;
      if (_appliedMode == PlaybackMode.shuffle) {
        _generateShuffleOrder(seedIndex: _currentIndex);
      }
      currentTrackNotifier.value = currentTrack;
      return true;
    }
    return false;
  }

  bool selectTrackByIndex(int index) {
    if (index >= 0 && index < _tracks.length) {
      _currentIndex = index;
      if (_appliedMode == PlaybackMode.shuffle) {
        _generateShuffleOrder(seedIndex: _currentIndex);
      }
      currentTrackNotifier.value = currentTrack;
      return true;
    }
    return false;
  }

  /// Dynamic continuation for intelligence mode (< 5 tracks remaining).
  Future<void> _continueIntelligenceBatch() async {
    if (_isContinuingIntelligence) return;
    if (_intelligenceBatchIndex >= maxIntelligenceBatches) {
      debugPrint('[CarMusicQueue] Intelligence batch limit reached ($maxIntelligenceBatches batches, max 150 tracks).');
      return;
    }
    if (_backendClient == null || _baseUrl.isEmpty || currentTrack == null) return;

    _isContinuingIntelligence = true;
    try {
      final nextBatchIndex = _intelligenceBatchIndex + 1;
      final seedSongId = currentTrack!.songId;
      final playlistId = _intelligencePlaylistId ?? 0;
      final requestId = 'req_intel_batch_${nextBatchIndex}_${DateTime.now().millisecondsSinceEpoch}';

      debugPrint('[CarMusicQueue] Requesting intelligence batch $nextBatchIndex (seed=$seedSongId)...');
      final res = await _backendClient!.requestIntelligenceBatch(
        baseUrl: _baseUrl,
        token: _token,
        requestId: requestId,
        seedSongId: seedSongId,
        playlistId: playlistId,
        batchIndex: nextBatchIndex,
        count: 30,
      );

      final rawTracks = res['tracks'] as List? ?? [];
      final oldTotal = _tracks.length;
      final newTracks = <NeteaseQueueTrackItem>[];

      for (int i = 0; i < rawTracks.length; i++) {
        if (rawTracks[i] is Map<String, dynamic>) {
          newTracks.add(NeteaseQueueTrackItem.fromJson(
            rawTracks[i] as Map<String, dynamic>,
            fallbackIndex: oldTotal + i,
          ));
        }
      }

      if (newTracks.isNotEmpty) {
        _tracks.addAll(newTracks);
        _total = _tracks.length;
        _queueVersion++;
        _intelligenceBatchIndex = nextBatchIndex;
        queueVersionNotifier.value = _queueVersion;
        debugPrint('[CarMusicQueue] Appended ${newTracks.length} tracks to intelligence queue (total=$_total, v$_queueVersion).');
      }
    } catch (e) {
      debugPrint('[CarMusicQueue] Intelligence continuation failed: $e');
      // No fake fallback! Keep existing tracks and allow natural playout.
    } finally {
      _isContinuingIntelligence = false;
    }
  }

  /// Sets up an authentic intelligence queue from a validated seed track.
  void initIntelligenceQueue({
    required String queueId,
    required int queueVersion,
    required List<NeteaseQueueTrackItem> initialTracks,
    required int playlistId,
  }) {
    _queueSource = QueueSource.neteaseIntelligence;
    _queueId = queueId;
    _queueVersion = queueVersion;
    _tracks.clear();
    _tracks.addAll(initialTracks);
    _total = initialTracks.length;
    _isComplete = true;
    _isFullyLoaded = true;
    _currentIndex = 0;
    _intelligenceBatchIndex = 0;
    _intelligencePlaylistId = playlistId;
    _appliedMode = PlaybackMode.intelligence;
    _requestedMode = PlaybackMode.intelligence;

    _consecutiveFailures = 0;
    _errorCode = null;
    _errorDetail = null;

    queueVersionNotifier.value = _queueVersion;
    currentTrackNotifier.value = currentTrack;
    appliedModeNotifier.value = _appliedMode;
  }

  /// Records a playback failure and evaluates the circuit breaker.
  CircuitBreakerAction recordPlaybackFailure(String reason) {
    _consecutiveFailures++;
    debugPrint('[CarMusicQueue] Playback failure recorded: count=$_consecutiveFailures/$maxConsecutiveFailures, reason=$reason');

    if (_consecutiveFailures >= maxConsecutiveFailures) {
      _errorCode = 'PLAYBACK_CONSECUTIVE_FAILURES';
      _errorDetail = '连续 3 首歌曲播放失败，触发熔断保护: $reason';
      return CircuitBreakerAction.stopPlayer;
    }
    return CircuitBreakerAction.skipToNext;
  }

  /// Resets failure counter upon successful playback start.
  void recordPlaybackSuccess() {
    if (_consecutiveFailures > 0 || _errorCode != null) {
      _consecutiveFailures = 0;
      _errorCode = null;
      _errorDetail = null;
    }
  }

  /// Clears in-memory queue state (e.g. on account logout or test teardown)
  void clear() {
    _tracks.clear();
    _queueId = '';
    _queueVersion = 0;
    _queueSource = QueueSource.neteaseFavorite;
    _total = 0;
    _isComplete = false;
    _isFullyLoaded = false;
    _currentIndex = 0;
    _shuffleIndices.clear();
    _shufflePosition = 0;
    _consecutiveFailures = 0;
    _errorCode = null;
    _errorDetail = null;
    queueVersionNotifier.value = 0;
    currentTrackNotifier.value = null;
  }
}
