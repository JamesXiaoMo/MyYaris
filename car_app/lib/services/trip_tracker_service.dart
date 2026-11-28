import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/obd_telemetry.dart';
import 'backend_client.dart';
import 'car_obd_service.dart';

/// Drains 10-second GPS samples collected natively by KeepAliveService (survives
/// backgrounding / navigation apps) and uploads them in batches to `/api/v1/trips/points`
/// with automatic trip segmentation and decoupled OBD telemetry reporting.
class TripTrackerService {
  static final TripTrackerService _instance = TripTrackerService._internal();
  factory TripTrackerService() => _instance;
  TripTrackerService._internal();

  static const MethodChannel _locationChannel =
      MethodChannel('com.myyaris.my_yaris/location');

  static const Duration sampleInterval = Duration(seconds: 10);
  static const Duration tripSplitGap = Duration(minutes: 15);
  static const int maxBufferedPoints = 2000;

  final ValueNotifier<bool> isRunningNotifier = ValueNotifier(false);
  final ValueNotifier<int> uploadedPointsNotifier = ValueNotifier(0);

  static const String _prefTripIdKey = 'myyaris_active_trip_id';
  static const String _prefLastPointMsKey = 'myyaris_active_trip_last_ms';

  Timer? _timer;
  bool _isRunning = false;
  bool _uploadInFlight = false;
  String _tripId = '';
  DateTime? _lastPointTime;
  String _baseUrl = '';
  String _deviceId = '';
  String _token = '';
  Map<String, String> _fallbackDns = const {};
  BackendClient? _persistentClient;
  final List<Map<String, dynamic>> _pendingPoints = [];

  Future<void> _restoreOrInitTripId(bool resetTrip) async {
    if (!resetTrip && _tripId.isEmpty) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final savedId = prefs.getString(_prefTripIdKey) ?? '';
        final savedMs = prefs.getInt(_prefLastPointMsKey) ?? 0;
        if (savedId.isNotEmpty && savedMs > 0) {
          final lastDt = DateTime.fromMillisecondsSinceEpoch(savedMs, isUtc: true);
          if (DateTime.now().toUtc().difference(lastDt).abs() < tripSplitGap) {
            _tripId = savedId;
            _lastPointTime = lastDt;
          }
        }
      } catch (_) {}
    }
    if (resetTrip || _tripId.isEmpty) {
      _tripId = 'trip_${DateTime.now().toUtc().millisecondsSinceEpoch}';
      uploadedPointsNotifier.value = 0;
      unawaited(_persistTripState());
    }
  }

  Future<void> _persistTripState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefTripIdKey, _tripId);
      if (_lastPointTime != null) {
        await prefs.setInt(
          _prefLastPointMsKey,
          _lastPointTime!.millisecondsSinceEpoch,
        );
      }
    } catch (_) {}
  }

  bool get isRunning => _isRunning;
  String get tripId => _tripId;

  BackendClient _getClient() {
    return _persistentClient ??= BackendClient(
      fallbackDns: _fallbackDns.isNotEmpty ? _fallbackDns : null,
    );
  }

  Future<void> start({
    required String baseUrl,
    required String deviceId,
    required String token,
    Map<String, String>? fallbackDns,
    bool resetTrip = false,
  }) async {
    final trimmedUrl = baseUrl.trim();
    if (trimmedUrl.isEmpty || trimmedUrl.contains('mock') || token.trim().isEmpty) {
      return;
    }
    _baseUrl = trimmedUrl.endsWith('/')
        ? trimmedUrl.substring(0, trimmedUrl.length - 1)
        : trimmedUrl;
    _deviceId = deviceId.trim().isEmpty ? 'car_p3pro' : deviceId.trim();
    _token = token.trim();
    _fallbackDns = fallbackDns ?? const {};
    _persistentClient?.close();
    _persistentClient = null;

    await _restoreOrInitTripId(resetTrip);

    if (_isRunning) return;
    _isRunning = true;
    isRunningNotifier.value = true;

    try {
      await _locationChannel.invokeMethod<bool>('startTracking');
    } catch (e) {
      debugPrint('[TripTracker] Native startTracking note: $e');
    }

    unawaited(_tick());
    _timer?.cancel();
    _timer = Timer.periodic(sampleInterval, (_) {
      unawaited(_tick());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _persistentClient?.close();
    _persistentClient = null;
    if (!_isRunning) return;
    _isRunning = false;
    isRunningNotifier.value = false;
    try {
      await _locationChannel.invokeMethod<bool>('stopTracking');
    } catch (_) {}
  }

  /// Sampling runs natively in KeepAliveService; every 10s we safely peek -> upload -> ack
  /// so GPS points are NEVER deleted from disk before HTTP 200 OK succeeds.
  Future<void> _tick() async {
    if (!_isRunning) return;
    if (!_uploadInFlight) {
      unawaited(_flushPendingAndObd());
    }
  }

  Map<String, dynamic>? _normalizeLocationMap(Map<dynamic, dynamic> loc) {
    final lat = (loc['latitude'] as num?)?.toDouble();
    final lon = (loc['longitude'] as num?)?.toDouble();
    if (lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        (lat == 0.0 && lon == 0.0) ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return null;
    }
    final speedKmh = (loc['speed_kmh'] as num?)?.toDouble();
    final accuracyM = (loc['accuracy_m'] as num?)?.toDouble();
    final tsMs = (loc['timestamp_ms'] as num?)?.toInt();
    final ptTime = tsMs != null && tsMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true)
        : DateTime.now().toUtc();

    return {
      '_pt_time_ms': ptTime.millisecondsSinceEpoch,
      'latitude': lat,
      'longitude': lon,
      if (speedKmh != null && speedKmh >= 0 && speedKmh <= 400)
        'speed_kmh': speedKmh,
      if (accuracyM != null && accuracyM >= 0 && accuracyM <= 5000)
        'accuracy_m': accuracyM,
      'recorded_at': ptTime.toIso8601String(),
    };
  }

  Future<void> _flushPendingAndObd() async {
    if (!_isRunning || _uploadInFlight) return;
    _uploadInFlight = true;
    try {
      // Phase 1: Two-phase crash-safe upload from native disk queue (peek -> upload -> ack)
      // Trip segmentation uses local cursor state and only commits after _postBatch succeeds!
      while (_isRunning) {
        List<dynamic>? peeked;
        try {
          peeked = await _locationChannel.invokeMethod<List<dynamic>>(
            'peekBufferedLocations',
            {'maxCount': 100},
          );
        } catch (_) {
          break;
        }
        if (peeked == null || peeked.isEmpty) break;

        final validBatch = <Map<String, dynamic>>[];
        String cursorTripId = _tripId;
        DateTime? cursorLastTime = _lastPointTime;
        String? batchTripId;
        int consumedRawCount = 0;

        for (final item in peeked) {
          if (item is! Map) {
            consumedRawCount++;
            continue;
          }
          final norm = _normalizeLocationMap(item);
          if (norm == null) {
            consumedRawCount++;
            continue;
          }
          final ptTime = DateTime.fromMillisecondsSinceEpoch(
            norm['_pt_time_ms'] as int,
            isUtc: true,
          );
          if (cursorLastTime != null &&
              ptTime.difference(cursorLastTime).abs() >= tripSplitGap) {
            cursorTripId = 'trip_${ptTime.millisecondsSinceEpoch}';
          }
          batchTripId ??= cursorTripId;
          if (cursorTripId != batchTripId) {
            // Stop before trip boundary so each batch maps to one trip_id
            break;
          }
          cursorLastTime = ptTime;
          consumedRawCount++;
          validBatch.add({
            for (final e in norm.entries)
              if (e.key != '_pt_time_ms') e.key: e.value,
          });
        }

        if (validBatch.isNotEmpty && batchTripId != null) {
          final ok = await _postBatch(batchTripId, validBatch);
          if (!ok) {
            // Keep points safely on disk and leave _tripId/_lastPointTime untouched for next retry!
            break;
          }
          _tripId = batchTripId;
          _lastPointTime = cursorLastTime;
          uploadedPointsNotifier.value += validBatch.length;
          unawaited(_persistTripState());
        }

        if (consumedRawCount > 0) {
          try {
            await _locationChannel.invokeMethod<int>(
              'ackBufferedLocations',
              {'count': consumedRawCount},
            );
          } catch (_) {
            break;
          }
        } else {
          break;
        }
      }

      // Phase 2: Fallback flush if any fresh points were queued in RAM
      while (_isRunning && _pendingPoints.isNotEmpty) {
        String cursorTripId = _tripId;
        DateTime? cursorLastTime = _lastPointTime;
        String? batchTripId;
        final batch = <Map<String, dynamic>>[];
        int takeCount = 0;
        for (final pt in _pendingPoints) {
          final ptTime = DateTime.fromMillisecondsSinceEpoch(
            pt['_pt_time_ms'] as int,
            isUtc: true,
          );
          if (cursorLastTime != null &&
              ptTime.difference(cursorLastTime).abs() >= tripSplitGap) {
            cursorTripId = 'trip_${ptTime.millisecondsSinceEpoch}';
          }
          batchTripId ??= cursorTripId;
          if (cursorTripId != batchTripId) break;
          cursorLastTime = ptTime;
          batch.add({
            for (final e in pt.entries)
              if (e.key != '_pt_time_ms') e.key: e.value,
          });
          takeCount++;
          if (batch.length >= 100) break;
        }
        if (batch.isEmpty || batchTripId == null) break;
        final ok = await _postBatch(batchTripId, batch);
        if (!ok) break;
        _tripId = batchTripId;
        _lastPointTime = cursorLastTime;
        _pendingPoints.removeRange(0, takeCount);
        uploadedPointsNotifier.value += batch.length;
        unawaited(_persistTripState());
      }

      await _uploadObdSnapshotIfReady();
    } finally {
      _uploadInFlight = false;
    }
  }

  Future<bool> _postBatch(String tripId, List<Map<String, dynamic>> points) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/trips/points');
      if (uri.scheme != 'https' && uri.scheme != 'http') return false;
      return await _getClient().uploadTripPoints(
        baseUrl: _baseUrl,
        token: _token,
        deviceId: _deviceId,
        tripId: tripId,
        points: points,
      );
    } catch (e) {
      debugPrint('[TripTracker] Upload batch deferred: $e');
      return false;
    }
  }

  Future<void> _uploadObdSnapshotIfReady() async {
    final telemetry = CarObdService().currentTelemetry;
    if (telemetry.status != ObdConnectionStatus.ready) return;
    try {
      await _getClient().uploadVehicleTelemetry(
        baseUrl: _baseUrl,
        token: _token,
        deviceId: _deviceId,
        telemetry: telemetry.toJson(),
      );
    } catch (e) {
      debugPrint('[TripTracker] OBD upload deferred: $e');
    }
  }
}
