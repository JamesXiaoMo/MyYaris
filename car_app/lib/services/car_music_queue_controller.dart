import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/music_queue_models.dart';
import 'backend_client.dart';

enum CircuitBreakerAction {
  skipToNext,
  stopPlayer,
}

/// Immutable backup snapshot of the complete queue controller state for transactional rollback
class QueueControllerStateBackup {
  final List<NeteaseQueueTrackItem> tracks;
  final String queueId;
  final int queueVersion;
  final String queueSource;
  final String? queueName;
  final int total;
  final bool isComplete;
  final bool isFullyLoaded;
  final int currentIndex;
  final PlaybackMode appliedMode;
  final List<int> shuffleIndices;
  final int shufflePosition;
  final int consecutiveFailures;
  final String? errorCode;
  final String? errorDetail;
  final int intelligenceBatchIndex;
  final int? intelligencePlaylistId;

  QueueControllerStateBackup({
    required this.tracks,
    required this.queueId,
    required this.queueVersion,
    required this.queueSource,
    this.queueName,
    required this.total,
    required this.isComplete,
    required this.isFullyLoaded,
    required this.currentIndex,
    required this.appliedMode,
    required this.shuffleIndices,
    required this.shufflePosition,
    required this.consecutiveFailures,
    this.errorCode,
    this.errorDetail,
    required this.intelligenceBatchIndex,
    this.intelligencePlaylistId,
  });

  NeteaseQueueTrackItem? get currentTrack =>
      (currentIndex >= 0 && currentIndex < tracks.length) ? tracks[currentIndex] : null;
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

  /// Creates an immutable backup of the complete controller state for transactional rollback
  QueueControllerStateBackup createBackup() {
    return QueueControllerStateBackup(
      tracks: List<NeteaseQueueTrackItem>.from(_tracks),
      queueId: _queueId,
      queueVersion: _queueVersion,
      queueSource: _queueSource,
      queueName: _queueName,
      total: _total,
      isComplete: _isComplete,
      isFullyLoaded: _isFullyLoaded,
      currentIndex: _currentIndex,
      appliedMode: _appliedMode,
      shuffleIndices: List<int>.from(_shuffleIndices),
      shufflePosition: _shufflePosition,
      consecutiveFailures: _consecutiveFailures,
      errorCode: _errorCode,
      errorDetail: _errorDetail,
      intelligenceBatchIndex: _intelligenceBatchIndex,
      intelligencePlaylistId: _intelligencePlaylistId,
    );
  }

  /// Restores complete controller state from backup upon transaction failure
  void restoreBackup(QueueControllerStateBackup backup) {
    _tracks.clear();
    _tracks.addAll(backup.tracks);
    _queueId = backup.queueId;
    _queueVersion = backup.queueVersion;
    _queueSource = backup.queueSource;
    _queueName = backup.queueName;
    _total = backup.total;
    _isComplete = backup.isComplete;
    _isFullyLoaded = backup.isFullyLoaded;
    _currentIndex = backup.currentIndex;
    _appliedMode = backup.appliedMode;
    _requestedMode = backup.appliedMode;
    _shuffleIndices.clear();
    _shuffleIndices.addAll(backup.shuffleIndices);
    _shufflePosition = backup.shufflePosition;
    _consecutiveFailures = backup.consecutiveFailures;
    _errorCode = backup.errorCode;
    _errorDetail = backup.errorDetail;
    _intelligenceBatchIndex = backup.intelligenceBatchIndex;
    _intelligencePlaylistId = backup.intelligencePlaylistId;

    queueVersionNotifier.value = _queueVersion;
    currentTrackNotifier.value = currentTrack;
    appliedModeNotifier.value = _appliedMode;
  }

  void setIntelligencePlaylistId(int? playlistId) {
    _intelligencePlaylistId = playlistId;
  }

  int? get intelligencePlaylistId => _intelligencePlaylistId;

  /// Fetches a complete queue snapshot candidate across pages without mutating controller state.
  /// Strictly verifies page source, total, offset continuity, is_complete, queue_state,
  /// has_more consistency, and rejects any disordered/non-monotonic track indices with 422.
  Future<MusicQueueSnapshot?> fetchAndValidateQueueSnapshot({
    String? queueId,
    int? queueVersion,
    required String source,
    int maxRetries = 3,
  }) async {
    if (_backendClient == null || _baseUrl.isEmpty) {
      debugPrint('[CarMusicQueue] Cannot fetch queue: BackendClient or baseUrl not configured');
      return null;
    }

    int retryCount = 0;
    while (retryCount < maxRetries) {
      try {
        debugPrint('[CarMusicQueue] Fetching candidate queue page 0 (source=$source, qid=$queueId, ver=$queueVersion, attempt=${retryCount + 1})...');
        final firstPage = await _backendClient!.fetchMusicQueuePage(
          baseUrl: _baseUrl,
          token: _token,
          deviceId: _deviceId,
          source: source,
          offset: 0,
          limit: 50,
          queueId: queueId,
          queueVersion: queueVersion,
        );

        final discoveredQid = firstPage.queueId;
        final discoveredVer = firstPage.queueVersion;
        final total = firstPage.total;

        // 1. Strict first page attributes validation
        if (discoveredQid.isEmpty) {
          throw BackendException(422, 'Received empty queue_id from backend');
        }
        if (firstPage.source != source) {
          throw BackendException(422, 'First page source mismatch: expected $source, got ${firstPage.source}');
        }
        if (firstPage.offset != 0) {
          throw BackendException(422, 'First page offset must be 0, got ${firstPage.offset}');
        }
        if (total <= 0) {
          throw BackendException(422, 'First page total must be positive, got $total');
        }
        if (queueId != null && queueId.isNotEmpty && discoveredQid != queueId) {
          throw BackendException(409, 'Queue ID mismatch: expected $queueId, got $discoveredQid');
        }
        if (queueVersion != null && discoveredVer != queueVersion) {
          throw BackendException(409, 'Queue version mismatch: expected $queueVersion, got $discoveredVer');
        }
        if (firstPage.queueState != 'ready') {
          throw BackendException(409, 'Queue state is not ready (state=${firstPage.queueState})');
        }
        final expectedFirstHasMore = firstPage.tracks.length < total;
        if (firstPage.hasMore != expectedFirstHasMore) {
          throw BackendException(422, 'First page has_more mismatch: expected $expectedFirstHasMore, got ${firstPage.hasMore}');
        }

        final buffer = <NeteaseQueueTrackItem>[];
        final seenTrackIds = <String>{};

        for (final track in firstPage.tracks) {
          if (track.queueIndex != buffer.length) {
            throw BackendException(422, 'Disordered track index in page 0: expected ${buffer.length}, got ${track.queueIndex}');
          }
          if (seenTrackIds.contains(track.trackId)) {
            throw BackendException(422, 'Duplicate track_id in page 0: ${track.trackId}');
          }
          seenTrackIds.add(track.trackId);
          buffer.add(track);
        }

        bool isComplete = firstPage.isComplete;
        String queueState = firstPage.queueState;

        // 2. Paginate remaining tracks
        while (buffer.length < total) {
          final expectedOffset = buffer.length;
          final nextPage = await _backendClient!.fetchMusicQueuePage(
            baseUrl: _baseUrl,
            token: _token,
            deviceId: _deviceId,
            source: source,
            offset: expectedOffset,
            limit: 50,
            queueId: discoveredQid,
            queueVersion: discoveredVer,
          );

          if (nextPage.source != source) {
            throw BackendException(422, 'Page source mismatch: expected $source, got ${nextPage.source}');
          }
          if (nextPage.total != total) {
            throw BackendException(422, 'Total shifted during pagination: expected $total, got ${nextPage.total}');
          }
          if (nextPage.queueId != discoveredQid || nextPage.queueVersion != discoveredVer) {
            throw BackendException(409, 'Queue version shifted during pagination: expected $discoveredVer, got ${nextPage.queueVersion}');
          }
          if (nextPage.offset != expectedOffset) {
            throw BackendException(422, 'Offset discontinuity: expected $expectedOffset, got ${nextPage.offset}');
          }
          if (nextPage.queueState != 'ready') {
            throw BackendException(409, 'Page queue state not ready: ${nextPage.queueState}');
          }
          if (nextPage.tracks.isEmpty) {
            throw BackendException(422, 'Received empty tracks array while buffer (${buffer.length}) < total ($total)');
          }
          final expectedNextHasMore = (buffer.length + nextPage.tracks.length) < total;
          if (nextPage.hasMore != expectedNextHasMore) {
            throw BackendException(422, 'Page has_more mismatch: expected $expectedNextHasMore, got ${nextPage.hasMore}');
          }

          for (final track in nextPage.tracks) {
            if (track.queueIndex != buffer.length) {
              throw BackendException(422, 'Disordered track index: expected ${buffer.length}, got ${track.queueIndex}');
            }
            if (seenTrackIds.contains(track.trackId)) {
              throw BackendException(422, 'Duplicate track_id encountered: ${track.trackId}');
            }
            seenTrackIds.add(track.trackId);
            buffer.add(track);
          }

          isComplete = nextPage.isComplete;
          queueState = nextPage.queueState;
        }

        // 3. Strict completeness & index validation
        if (buffer.length != total) {
          throw BackendException(422, 'Buffer track count mismatch: expected $total, got ${buffer.length}');
        }
        if (!isComplete && source != QueueSource.neteaseIntelligence) {
          throw BackendException(409, 'Queue snapshot is not complete (is_complete=false)');
        }
        if (queueState != 'ready') {
          throw BackendException(409, 'Queue state is not ready (state=$queueState)');
        }

        // Double check index monotonicity (strictly 0..total-1)
        for (int i = 0; i < buffer.length; i++) {
          if (buffer[i].queueIndex != i) {
            throw BackendException(422, 'Disordered track index at $i: expected $i, got ${buffer[i].queueIndex}');
          }
        }

        return MusicQueueSnapshot(
          code: 200,
          queueId: discoveredQid,
          queueVersion: discoveredVer,
          source: source,
          name: firstPage.name ?? (source == QueueSource.neteaseFavorite ? '我喜欢的音乐' : '播放队列'),
          total: total,
          isComplete: isComplete,
          batchIndex: firstPage.batchIndex,
          queueState: 'ready',
          offset: 0,
          limit: total,
          hasMore: false,
          tracks: buffer,
        );
      } on BackendException catch (e) {
        debugPrint('[CarMusicQueue] BackendException fetching queue: ${e.statusCode} ${e.message}');
        if (e.statusCode == 409) {
          retryCount++;
          await Future.delayed(Duration(milliseconds: 300 * retryCount));
          continue;
        }
        _errorCode = 'LOAD_QUEUE_FAILED';
        _errorDetail = e.message;
        return null;
      } catch (e) {
        debugPrint('[CarMusicQueue] Error fetching queue: $e');
        retryCount++;
        await Future.delayed(Duration(milliseconds: 300 * retryCount));
      }
    }

    _errorCode = 'LOAD_QUEUE_RETRIES_EXCEEDED';
    _errorDetail = '加载队列连续 $maxRetries 次失败，已保留原播放队列';
    return null;
  }

  /// Atomically applies a validated candidate queue snapshot to the active controller state
  void applyQueueSnapshot(
    MusicQueueSnapshot snapshot, {
    int targetIndex = 0,
    PlaybackMode? mode,
  }) {
    _tracks.clear();
    _tracks.addAll(snapshot.tracks);
    _queueId = snapshot.queueId;
    _queueVersion = snapshot.queueVersion;
    _queueSource = snapshot.source;
    _queueName = snapshot.name;
    _total = snapshot.total;
    _isComplete = snapshot.isComplete;
    _isFullyLoaded = _tracks.length == snapshot.total;
    _intelligenceBatchIndex = snapshot.batchIndex;

    if (targetIndex >= 0 && targetIndex < _tracks.length) {
      _currentIndex = targetIndex;
    } else {
      _currentIndex = 0;
    }

    if (mode != null) {
      _appliedMode = mode;
      _requestedMode = mode;
      appliedModeNotifier.value = mode;
    }

    if (_appliedMode == PlaybackMode.shuffle) {
      _generateShuffleOrder(seedIndex: _currentIndex);
    }

    _consecutiveFailures = 0;
    _errorCode = null;
    _errorDetail = null;

    queueVersionNotifier.value = _queueVersion;
    currentTrackNotifier.value = currentTrack;
    debugPrint('[CarMusicQueue] Queue atomically applied: $_queueId v$_queueVersion ($_total tracks, source=$_queueSource, index=$_currentIndex)');
  }

  /// Convenience method that fetches candidate snapshot and atomically applies it if successful
  Future<bool> loadQueueSnapshotWithPaging({
    String? queueId,
    int? queueVersion,
    required String source,
    int targetIndex = 0,
    int maxRetries = 3,
  }) async {
    final candidate = await fetchAndValidateQueueSnapshot(
      queueId: queueId,
      queueVersion: queueVersion,
      source: source,
      maxRetries: maxRetries,
    );
    if (candidate == null) return false;
    applyQueueSnapshot(candidate, targetIndex: targetIndex);
    return true;
  }

  /// Fetches the full favorite playlist across pages with version locking and bounded retry.
  Future<bool> loadFullFavoriteQueue({int maxRetries = 3}) {
    return loadQueueSnapshotWithPaging(
      source: QueueSource.neteaseFavorite,
      maxRetries: maxRetries,
    );
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
    if ((mode == PlaybackMode.listLoop || mode == PlaybackMode.shuffle) &&
        (_queueSource != QueueSource.neteaseFavorite || !_isFullyLoaded)) {
      return false;
    }
    if (mode == PlaybackMode.intelligence && _queueSource != QueueSource.neteaseIntelligence) return false;

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
        if (_appliedMode != PlaybackMode.shuffle || _shuffleIndices.length != _tracks.length) {
          _generateShuffleOrder(seedIndex: _currentIndex);
        }
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
    if (_queueSource == QueueSource.singleTrack && _appliedMode != PlaybackMode.singleLoop) {
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
        _shufflePosition = _tracks.length > 1 ? 1 : 0;
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

  Future<NeteaseQueueTrackItem?> nextTrackForPlayback() async {
    if (_appliedMode == PlaybackMode.intelligence && _queueSource == QueueSource.neteaseIntelligence &&
        _currentIndex >= _tracks.length - 5) {
      await _continueIntelligenceBatch();
    }
    return getNextTrack();
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
    if (_appliedMode != PlaybackMode.intelligence) return;
    if (_isContinuingIntelligence) return;
    if (_intelligenceBatchIndex >= maxIntelligenceBatches) {
      _errorCode = 'INTELLIGENCE_QUEUE_EXHAUSTED';
      _errorDetail = '心动模式推荐曲目已达上限 ($maxIntelligenceBatches batches, max 150 tracks)';
      debugPrint('[CarMusicQueue] $_errorDetail');
      return;
    }
    if (_backendClient == null || _baseUrl.isEmpty || _tracks.isEmpty) return;

    _isContinuingIntelligence = true;
    final originalQueueId = _queueId;
    final originalVersion = _queueVersion;
    try {
      final nextBatchIndex = _intelligenceBatchIndex + 1;
      final seedSongId = _tracks.last.songId > 0 ? _tracks.last.songId : (currentTrack?.songId ?? 0);
      if (seedSongId <= 0) {
        _errorCode = 'INVALID_SEED_SONG';
        _errorDetail = '缺少合法的心动续批种子歌曲ID';
        debugPrint('[CarMusicQueue] $_errorDetail');
        return;
      }
      final requestId = 'req_intel_${_queueId}_b$nextBatchIndex';

      debugPrint('[CarMusicQueue] Requesting intelligence batch $nextBatchIndex (seed=$seedSongId, req=$requestId)...');
      final res = await _backendClient!.requestIntelligenceBatch(
        baseUrl: _baseUrl,
        token: _token,
        requestId: requestId,
        deviceId: _deviceId,
        queueId: originalQueueId,
        queueVersion: originalVersion,
        seedSongId: seedSongId,
        playlistId: _intelligencePlaylistId,
        batchIndex: nextBatchIndex,
        count: 30,
      );

      if (_queueId != originalQueueId || _queueVersion != originalVersion || _appliedMode != PlaybackMode.intelligence) return;
      final returnedMode = res['mode']?.toString();
      if (returnedMode != 'intelligence') {
        throw BackendException(422, 'Invalid intelligence mode response: $returnedMode');
      }

      final returnedQueueId = res['queue_id']?.toString();
      if (returnedQueueId != null && returnedQueueId.isNotEmpty && returnedQueueId != _queueId) {
        throw BackendException(409, 'Intelligence queue_id shifted: expected $_queueId, got $returnedQueueId');
      }

      final newVersion = (res['queue_version'] as num?)?.toInt();
      if (newVersion == null || newVersion <= originalVersion) {
        throw BackendException(422, 'Invalid or missing queue_version in intelligence response');
      }

      final rawTracks = res['tracks'] as List? ?? [];
      final parsedTracks = <NeteaseQueueTrackItem>[];
      for (int i = 0; i < rawTracks.length; i++) {
        if (rawTracks[i] is Map<String, dynamic>) {
          parsedTracks.add(NeteaseQueueTrackItem.fromJson(rawTracks[i] as Map<String, dynamic>));
        }
      }

      if (parsedTracks.isEmpty) throw BackendException(503, 'INTELLIGENCE_QUEUE_EXHAUSTED');
      // Validate before mutation, including appended-batch responses.
      final oldTracks = List<NeteaseQueueTrackItem>.from(_tracks);
      // Check whether server returned the full updated list or just the appended batch
      if (parsedTracks.length >= _tracks.length && parsedTracks.isNotEmpty && parsedTracks[0].trackId == _tracks[0].trackId) {
        // Full list returned: verify old prefix is 100% intact
        for (int i = 0; i < _tracks.length; i++) {
          if (parsedTracks[i].trackId != _tracks[i].trackId || parsedTracks[i].queueIndex != i) {
            throw BackendException(422, 'Prefix inconsistency in replenished tracks at index $i');
          }
        }
        // Verify newly added tracks have monotonic indices and no duplicate IDs
        final seenIds = _tracks.map((t) => t.trackId).toSet();
        for (int i = _tracks.length; i < parsedTracks.length; i++) {
          if (parsedTracks[i].queueIndex != i) {
            throw BackendException(422, 'Disordered track index in replenished tracks: expected $i, got ${parsedTracks[i].queueIndex}');
          }
          if (seenIds.contains(parsedTracks[i].trackId)) {
            throw BackendException(422, 'Duplicate track_id in replenished tracks: ${parsedTracks[i].trackId}');
          }
          seenIds.add(parsedTracks[i].trackId);
        }
        _tracks.clear();
        _tracks.addAll(parsedTracks);
      } else {
        // Appended batch returned: verify sequential continuation and no duplicates
        final seenIds = _tracks.map((t) => t.trackId).toSet();
        final startIdx = _tracks.length;
        for (int i = 0; i < parsedTracks.length; i++) {
          final expectedIdx = startIdx + i;
          if (parsedTracks[i].queueIndex != expectedIdx) {
            throw BackendException(422, 'Disordered track index in replenishment batch: expected $expectedIdx, got ${parsedTracks[i].queueIndex}');
          }
          if (seenIds.contains(parsedTracks[i].trackId)) {
            throw BackendException(422, 'Duplicate track_id in replenishment batch: ${parsedTracks[i].trackId}');
          }
          seenIds.add(parsedTracks[i].trackId);
        }
        _tracks.addAll(parsedTracks);
      }
      if (_tracks.length <= oldTracks.length) throw BackendException(503, 'INTELLIGENCE_QUEUE_EXHAUSTED');

      _total = _tracks.length;
      _queueVersion = newVersion;
      _intelligenceBatchIndex = nextBatchIndex;
      _errorCode = null;
      _errorDetail = null;
      queueVersionNotifier.value = _queueVersion;
      debugPrint('[CarMusicQueue] Intelligence replenishment succeeded: batch=$nextBatchIndex, total=$_total, v$_queueVersion');
    } on BackendException catch (e) {
      if (_queueId != originalQueueId || _appliedMode != PlaybackMode.intelligence) return;
      debugPrint('[CarMusicQueue] BackendException in intelligence continuation: ${e.statusCode} ${e.message}');
      if (e.statusCode == 503 || e.message.contains('INTELLIGENCE_QUEUE_EXHAUSTED')) {
        _errorCode = 'INTELLIGENCE_QUEUE_EXHAUSTED';
        _errorDetail = '心动模式推荐曲目已达上限';
        _intelligenceBatchIndex = maxIntelligenceBatches;
      } else {
        _errorCode = 'INTELLIGENCE_CONTINUE_FAILED';
        _errorDetail = e.message;
      }
    } catch (e) {
      debugPrint('[CarMusicQueue] Intelligence continuation error: $e');
      _errorCode = 'INTELLIGENCE_CONTINUE_ERROR';
      _errorDetail = e.toString();
    } finally {
      _isContinuingIntelligence = false;
    }
  }

  /// Exposed for testing intelligence continuation explicitly
  @visibleForTesting
  Future<void> continueIntelligenceBatchForTesting() => _continueIntelligenceBatch();

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
    _errorCode = 'TRACK_UNPLAYABLE';
    _errorDetail = '歌曲不可播放（连续失败 $_consecutiveFailures/3）';
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
    _appliedMode = PlaybackMode.listLoop;
    queueVersionNotifier.value = 0;
    currentTrackNotifier.value = null;
    appliedModeNotifier.value = PlaybackMode.listLoop;
  }
}
