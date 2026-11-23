import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/music_queue_models.dart';
import 'backend_client.dart';
import 'car_music_queue_controller.dart';

enum BatchCacheState { idle, running, paused, completed, error }

class BatchCacheProgress {
  final BatchCacheState state;
  final int total;
  final int done;
  final int skipped;
  final int failed;
  final String message;

  const BatchCacheProgress({
    this.state = BatchCacheState.idle,
    this.total = 0,
    this.done = 0,
    this.skipped = 0,
    this.failed = 0,
    this.message = '',
  });
}

/// Manages local SD-card audio caching:
/// - Mode A: Cache-on-play (transparent background save while streaming) + instant zero-data local playback.
/// - Mode B: Manual Wi-Fi-only batch offline caching of the complete liked playlist with pause/resume.
class MusicCacheService {
  static final MusicCacheService _instance = MusicCacheService._internal();
  factory MusicCacheService() => _instance;
  MusicCacheService._internal();

  static const MethodChannel _storageChannel =
      MethodChannel('com.myyaris.my_yaris/storage');
  static const String _prefCacheOnPlayKey = 'myyaris_music_cache_on_play';
  static const String _prefBatchSpeedLimitKey = 'myyaris_music_batch_speed_limit_kbps';
  static const int minValidAudioBytes = 8192;

  /// Supported Wi-Fi batch cache speed limit presets (KB/s; 0 = unlimited).
  static const List<int> speedLimitPresetsKBps = [0, 512, 1024, 2048, 5120];

  final ValueNotifier<bool> cacheOnPlayNotifier = ValueNotifier(true);
  final ValueNotifier<int> batchSpeedLimitKBpsNotifier = ValueNotifier(0);
  final ValueNotifier<int> cachedCountNotifier = ValueNotifier(0);
  final ValueNotifier<int> cachedBytesNotifier = ValueNotifier(0);
  final ValueNotifier<String> storageSummaryNotifier = ValueNotifier('正在检测存储…');
  final ValueNotifier<BatchCacheProgress> batchProgressNotifier =
      ValueNotifier(const BatchCacheProgress());

  Directory? _cacheDir;
  final List<Directory> _allCacheDirs = [];
  bool _isSdCard = false;
  int _freeBytes = 0;
  bool _initialized = false;
  bool _hasOverrideDir = false;

  // Guard concurrent downloads of the same song
  final Set<int> _inFlightSongs = {};
  bool _batchStopRequested = false;

  @visibleForTesting
  Future<bool> Function()? wifiCheckerOverride;

  bool get isSdCard => _isSdCard;
  Directory? get cacheDir => _cacheDir;

  Future<void> init({Directory? overrideDir}) async {
    if (overrideDir != null) {
      _hasOverrideDir = true;
      _cacheDir = overrideDir;
      _allCacheDirs
        ..clear()
        ..add(overrideDir);
      if (!await _cacheDir!.exists()) await _cacheDir!.create(recursive: true);
      _isSdCard = true;
      _initialized = true;
      await refreshStats();
      return;
    }
    if (_initialized && _cacheDir != null && _isSdCard) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      cacheOnPlayNotifier.value = prefs.getBool(_prefCacheOnPlayKey) ?? true;
      batchSpeedLimitKBpsNotifier.value =
          prefs.getInt(_prefBatchSpeedLimitKey) ?? 0;
    } catch (_) {}

    await refreshStorageLocation();
    _initialized = true;
    await _cleanupOrphanedTmpFiles();
    await refreshStats();
  }

  /// Re-queries Android storage so if the removable SD card mounted after app boot,
  /// caching immediately switches to the SD card instead of duplicating into internal storage.
  Future<void> refreshStorageLocation() async {
    if (_hasOverrideDir) return;
    try {
      final info = await _storageChannel.invokeMapMethod<String, dynamic>(
        'getMusicCacheDir',
      );
      final path = info?['path']?.toString();
      if (path != null && path.isNotEmpty) {
        _cacheDir = Directory(path);
        if (!await _cacheDir!.exists()) {
          await _cacheDir!.create(recursive: true);
        }
        _isSdCard = info?['isSdCard'] == true;
        _freeBytes = (info?['freeBytes'] as num?)?.toInt() ?? 0;
        _allCacheDirs.clear();
        _allCacheDirs.add(_cacheDir!);
        final rawAll = info?['allPaths'];
        if (rawAll is List) {
          for (final p in rawAll) {
            final s = p?.toString() ?? '';
            if (s.isNotEmpty && s != _cacheDir!.path) {
              _allCacheDirs.add(Directory(s));
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[MusicCache] Native storage channel unavailable: $e');
    }
  }

  Future<void> _cleanupOrphanedTmpFiles() async {
    final dir = _cacheDir;
    if (dir == null || !await dir.exists()) return;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.tmp')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  Future<void> setCacheOnPlay(bool enabled) async {
    cacheOnPlayNotifier.value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefCacheOnPlayKey, enabled);
    } catch (_) {}
  }

  Future<void> setBatchSpeedLimitKBps(int kbps) async {
    final safe = kbps < 0 ? 0 : kbps;
    batchSpeedLimitKBpsNotifier.value = safe;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_prefBatchSpeedLimitKey, safe);
    } catch (_) {}
  }

  static String formatSpeedLimitLabel(int kbps) {
    if (kbps <= 0) return '不限速';
    if (kbps >= 1024 && kbps % 1024 == 0) return '${kbps ~/ 1024} MB/s';
    return '$kbps KB/s';
  }

  File? _fileForSong(int songId) {
    if (_cacheDir == null || songId <= 0) return null;
    return File('${_cacheDir!.path}/song_$songId.audio');
  }

  /// Returns a validated local audio file if cached in the active SD card or fallback cache dir.
  File? getCachedFile(int songId) {
    if (songId <= 0) return null;
    final dirs = _allCacheDirs.isNotEmpty
        ? _allCacheDirs
        : (_cacheDir != null ? [_cacheDir!] : const <Directory>[]);
    for (final dir in dirs) {
      final file = File('${dir.path}/song_$songId.audio');
      try {
        if (file.existsSync() && file.lengthSync() >= minValidAudioBytes) {
          return file;
        }
      } catch (_) {}
    }
    return null;
  }

  Future<bool> isOnWifi() async {
    if (wifiCheckerOverride != null) return wifiCheckerOverride!();
    try {
      return await _storageChannel.invokeMethod<bool>('isOnWifi') == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> refreshStats() async {
    final dir = _cacheDir;
    if (dir == null || !await dir.exists()) {
      cachedCountNotifier.value = 0;
      cachedBytesNotifier.value = 0;
      storageSummaryNotifier.value = '未检测到可用缓存目录';
      return;
    }
    int count = 0;
    int bytes = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.audio')) {
          final len = await entity.length();
          if (len >= minValidAudioBytes) {
            count++;
            bytes += len;
          }
        }
      }
    } catch (_) {}

    cachedCountNotifier.value = count;
    cachedBytesNotifier.value = bytes;
    final locLabel = _isSdCard ? '外置 SD 卡' : '车机内置存储';
    final freeGb = _freeBytes > 0
        ? ' · 可用 ${(_freeBytes / (1024 * 1024 * 1024)).toStringAsFixed(0)} GB'
        : '';
    storageSummaryNotifier.value = '$locLabel$freeGb';
  }

  /// Validates common audio container headers (ID3/MP3, OGG, FLAC, WAV, MP4/M4A).
  static bool hasValidAudioHeader(List<int> sample) {
    if (sample.length < 12) return false;
    bool starts(List<int> prefix) {
      for (var i = 0; i < prefix.length; i++) {
        if (sample[i] != prefix[i]) return false;
      }
      return true;
    }

    if (starts([0x49, 0x44, 0x33])) return true; // ID3 (MP3)
    if (sample[0] == 0xFF && (sample[1] & 0xE0) == 0xE0) return true; // MP3 frame sync
    if (starts([0x4F, 0x67, 0x67, 0x53])) return true; // OggS
    if (starts([0x66, 0x4C, 0x61, 0x43])) return true; // fLaC
    if (starts([0x52, 0x49, 0x46, 0x46]) &&
        sample[8] == 0x57 &&
        sample[9] == 0x41 &&
        sample[10] == 0x56 &&
        sample[11] == 0x45) {
      return true; // RIFF WAVE
    }
    if (sample[4] == 0x66 &&
        sample[5] == 0x74 &&
        sample[6] == 0x79 &&
        sample[7] == 0x70) {
      return true; // ISO BMFF / ftyp (M4A/AAC)
    }
    return false;
  }

  /// Downloads one track atomically to `.tmp` then renames to `.audio`.
  /// Supports optional byte-rate throttling (`maxBytesPerSecond > 0`) and
  /// mid-file abort when batch caching is paused.
  Future<bool> downloadTrack({
    required int songId,
    required String fullStreamUrl,
    required String token,
    BackendClient? backendClient,
    Map<String, String>? fallbackDns,
    String qualityLevel = 'exhigh',
    int maxBytesPerSecond = 0,
    bool abortOnBatchStop = false,
  }) async {
    if (!_initialized) await init();
    if (_cacheDir == null || songId <= 0) return false;
    if (getCachedFile(songId) != null) return true;
    if (!_inFlightSongs.add(songId)) return false;

    final finalFile = _fileForSong(songId)!;
    final tmpFile = File('${finalFile.path}.tmp');
    final ownsClient = backendClient == null;
    final client = backendClient ??
        BackendClient(
          fallbackDns:
              (fallbackDns != null && fallbackDns.isNotEmpty) ? fallbackDns : null,
        );

    try {
      final parsedUri = Uri.parse(fullStreamUrl);
      if (parsedUri.scheme != 'https' && parsedUri.scheme != 'http') return false;
      final qp = Map<String, String>.from(parsedUri.queryParameters);
      qp.putIfAbsent('level', () => qualityLevel);
      final uri = parsedUri.replace(queryParameters: qp);
      final req = await client.httpClient.getUrl(uri);
      if (token.isNotEmpty) {
        req.headers.set('X-Device-Token', token);
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      final res = await req.close().timeout(const Duration(seconds: 180));
      if (res.statusCode != 200) {
        await res.drain<void>();
        return false;
      }

      if (await tmpFile.exists()) await tmpFile.delete();
      final sink = tmpFile.openWrite();
      final headerBytes = <int>[];
      int totalBytes = 0;
      final sw = Stopwatch()..start();
      bool aborted = false;

      try {
        await for (final chunk in res) {
          if (abortOnBatchStop && _batchStopRequested) {
            aborted = true;
            break;
          }
          if (headerBytes.length < 16) {
            final need = 16 - headerBytes.length;
            headerBytes.addAll(chunk.take(need));
          }
          totalBytes += chunk.length;
          sink.add(chunk);

          // Live dynamic speed limit check (respects user changing limit mid-download)
          final activeLimitBps = abortOnBatchStop
              ? (batchSpeedLimitKBpsNotifier.value * 1024)
              : maxBytesPerSecond;
          if (activeLimitBps > 0) {
            final expectedMs = (totalBytes * 1000) ~/ activeLimitBps;
            final deltaMs = expectedMs - sw.elapsedMilliseconds;
            if (deltaMs > 15) {
              await Future<void>.delayed(Duration(milliseconds: deltaMs.clamp(15, 2000)));
            }
          }
        }
        if (!aborted) {
          await sink.flush();
        }
      } finally {
        await sink.close();
      }

      if (aborted || totalBytes < minValidAudioBytes || !hasValidAudioHeader(headerBytes)) {
        if (await tmpFile.exists()) await tmpFile.delete();
        return false;
      }

      await tmpFile.rename(finalFile.path);
      cachedCountNotifier.value = cachedCountNotifier.value + 1;
      cachedBytesNotifier.value = cachedBytesNotifier.value + totalBytes;
      return true;
    } catch (e) {
      debugPrint('[MusicCache] Download song $songId failed: $e');
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      return false;
    } finally {
      _inFlightSongs.remove(songId);
      if (ownsClient) client.close();
    }
  }

  /// Mode A: Background cache-on-play hook (never blocks playback).
  /// Uses `exhigh` (320kbps) so it reuses the server's cached stream with zero duplicate downloads.
  void cacheInBackgroundIfEnabled({
    required int songId,
    required String fullStreamUrl,
    required String token,
    Map<String, String>? fallbackDns,
  }) {
    if (!cacheOnPlayNotifier.value) return;
    if (batchProgressNotifier.value.state == BatchCacheState.running) return;
    if (getCachedFile(songId) != null) return;
    unawaited(
      downloadTrack(
        songId: songId,
        fullStreamUrl: fullStreamUrl,
        token: token,
        fallbackDns: fallbackDns,
        qualityLevel: 'exhigh',
      ),
    );
  }

  /// Mode B: Wi-Fi-only batch cache of the full liked playlist.
  Future<void> startBatchCacheFavorites({
    required String baseUrl,
    required String token,
    required String deviceId,
    Map<String, String>? fallbackDns,
    List<NeteaseQueueTrackItem>? overrideTracks,
    BackendClient? overrideClient,
  }) async {
    if (batchProgressNotifier.value.state == BatchCacheState.running) return;
    if (!_initialized) {
      await init();
    } else if (!_isSdCard && !_hasOverrideDir) {
      // Re-check if removable SD card has finished mounting since app boot
      await refreshStorageLocation();
      await refreshStats();
    }
    if (_cacheDir == null) {
      batchProgressNotifier.value = const BatchCacheProgress(
        state: BatchCacheState.error,
        message: '未找到可用存储目录',
      );
      return;
    }

    final wifi = await isOnWifi();
    if (!wifi) {
      batchProgressNotifier.value = const BatchCacheProgress(
        state: BatchCacheState.error,
        message: '仅允许在 Wi-Fi 下批量缓存，当前未连接 Wi-Fi',
      );
      return;
    }

    _batchStopRequested = false;
    batchProgressNotifier.value = const BatchCacheProgress(
      state: BatchCacheState.running,
      message: '正在获取完整喜欢歌单…',
    );

    final normalizedBase = baseUrl.trim().endsWith('/')
        ? baseUrl.trim().substring(0, baseUrl.trim().length - 1)
        : baseUrl.trim();
    final ownsClient = overrideClient == null;
    final client = overrideClient ??
        BackendClient(
          fallbackDns:
              (fallbackDns != null && fallbackDns.isNotEmpty) ? fallbackDns : null,
        );

    try {
      List<NeteaseQueueTrackItem> tracks;
      if (overrideTracks != null) {
        tracks = overrideTracks;
      } else {
        final ctrl = CarMusicQueueController();
        ctrl.configure(
          baseUrl: normalizedBase,
          token: token,
          deviceId: deviceId,
          backendClient: client,
        );
        final snap = await ctrl.fetchAndValidateQueueSnapshot(
          source: QueueSource.neteaseFavorite,
        );
        if (snap == null || snap.tracks.isEmpty) {
          batchProgressNotifier.value = const BatchCacheProgress(
            state: BatchCacheState.error,
            message: '未能获取喜欢歌单，请检查后端连接',
          );
          return;
        }
        tracks = snap.tracks;
      }

      // Deduplicate by songId so no track can ever be queued twice in one batch
      final dedupedTracks = <NeteaseQueueTrackItem>[];
      final seenSongIds = <int>{};
      for (final item in tracks) {
        if (item.songId > 0 && seenSongIds.add(item.songId)) {
          dedupedTracks.add(item);
        }
      }

      final total = dedupedTracks.length;
      int done = 0;
      int skipped = 0;
      int failed = 0;

      for (var i = 0; i < total; i++) {
        if (_batchStopRequested) {
          batchProgressNotifier.value = BatchCacheProgress(
            state: BatchCacheState.paused,
            total: total,
            done: done,
            skipped: skipped,
            failed: failed,
            message: '已暂停（已缓存 $done / $total 首）',
          );
          return;
        }

        if (i % 5 == 0 && !(await isOnWifi())) {
          batchProgressNotifier.value = BatchCacheProgress(
            state: BatchCacheState.paused,
            total: total,
            done: done,
            skipped: skipped,
            failed: failed,
            message: 'Wi-Fi 已断开，已自动暂停以保护流量',
          );
          return;
        }

        final t = dedupedTracks[i];
        if (getCachedFile(t.songId) != null) {
          done++;
          skipped++;
          batchProgressNotifier.value = BatchCacheProgress(
            state: BatchCacheState.running,
            total: total,
            done: done,
            skipped: skipped,
            failed: failed,
            message: '跳过已缓存：$done / $total',
          );
          continue;
        }

        if (t.playable == false || t.streamUrl.isEmpty) {
          failed++;
          continue;
        }

        final url = t.streamUrl.startsWith('/')
            ? '$normalizedBase${t.streamUrl}'
            : t.streamUrl;

        final limitLabel = formatSpeedLimitLabel(batchSpeedLimitKBpsNotifier.value);
        batchProgressNotifier.value = BatchCacheProgress(
          state: BatchCacheState.running,
          total: total,
          done: done,
          skipped: skipped,
          failed: failed,
          message: '正在缓存（${done + 1}/$total · $limitLabel）：${t.title}',
        );

        final ok = await downloadTrack(
          songId: t.songId,
          fullStreamUrl: url,
          token: token,
          backendClient: client,
          qualityLevel: 'lossless',
          maxBytesPerSecond: batchSpeedLimitKBpsNotifier.value * 1024,
          abortOnBatchStop: true,
        );
        if (ok) {
          done++;
        } else {
          failed++;
        }

        // Gentle pacing to avoid upstream rate limits
        if (!_batchStopRequested && overrideTracks == null) {
          await Future<void>.delayed(const Duration(milliseconds: 800));
        }
      }

      await refreshStats();
      batchProgressNotifier.value = BatchCacheProgress(
        state: BatchCacheState.completed,
        total: total,
        done: done,
        skipped: skipped,
        failed: failed,
        message: '缓存完成：$done / $total 首可用（失败 $failed 首）',
      );
    } catch (e) {
      batchProgressNotifier.value = BatchCacheProgress(
        state: BatchCacheState.error,
        message: '批量缓存中断：$e',
      );
    } finally {
      if (ownsClient) client.close();
    }
  }

  void pauseBatch() {
    _batchStopRequested = true;
  }

  Future<void> clearAllCache() async {
    _batchStopRequested = true;
    final dir = _cacheDir;
    if (dir != null && await dir.exists()) {
      try {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is File &&
              (entity.path.endsWith('.audio') || entity.path.endsWith('.tmp'))) {
            await entity.delete();
          }
        }
      } catch (_) {}
    }
    await refreshStats();
    batchProgressNotifier.value = const BatchCacheProgress(
      state: BatchCacheState.idle,
      message: '已清空本地缓存',
    );
  }
}
