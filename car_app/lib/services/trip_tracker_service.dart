import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

    if (resetTrip || _tripId.isEmpty) {
      _tripId = 'trip_${DateTime.now().toUtc().millisecondsSinceEpoch}';
      uploadedPointsNotifier.value = 0;
    }

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

  /// Sampling ALWAYS runs every 10s regardless of whether an HTTP upload is in flight.
  Future<void> _tick() async {
    if (!_isRunning) return;
    await _collectNativePoints();
    if (!_uploadInFlight) {
      unawaited(_flushPendingAndObd());
    }
  }

  void _appendLocationMap(Map<dynamic, dynamic> loc) {
    final lat = (loc['latitude'] as num?)?.toDouble();
    final lon = (loc['longitude'] as num?)?.toDouble();
    if (lat == null ||
        lon == null ||
        !lat.isFinite ||
        !lon.isFinite ||
        (lat == 0.0 && lon == 0.0) ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return;
    }
    final speedKmh = (loc['speed_kmh'] as num?)?.toDouble();
    final accuracyM = (loc['accuracy_m'] as num?)?.toDouble();
    final tsMs = (loc['timestamp_ms'] as num?)?.toInt();
    final ptTime = tsMs != null && tsMs > 0
        ? DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true)
        : DateTime.now().toUtc();

    // Auto-start a new trip if parked / idle for >= 15 minutes
    if (_lastPointTime != null &&
        ptTime.difference(_lastPointTime!).abs() >= tripSplitGap) {
      _tripId = 'trip_${ptTime.millisecondsSinceEpoch}';
    }
    _lastPointTime = ptTime;

    _pendingPoints.add({
      '_trip_id': _tripId,
      'latitude': lat,
      'longitude': lon,
      if (speedKmh != null && speedKmh >= 0 && speedKmh <= 400)
        'speed_kmh': speedKmh,
      if (accuracyM != null && accuracyM >= 0 && accuracyM <= 5000)
        'accuracy_m': accuracyM,
      'recorded_at': ptTime.toIso8601String(),
    });
    if (_pendingPoints.length > maxBufferedPoints) {
      _pendingPoints.removeRange(0, _pendingPoints.length - maxBufferedPoints);
    }
  }

  Future<void> _collectNativePoints() async {
    try {
      final drained = await _locationChannel.invokeMethod<List<dynamic>>(
        'drainBufferedLocations',
      );
      if (drained != null && drained.isNotEmpty) {
        for (final item in drained) {
          if (item is Map) _appendLocationMap(item);
        }
        return;
      }
    } catch (_) {}

    // Fallback to single getLatestLocation if native buffer returned empty
    try {
      final loc = await _locationChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getLatestLocation',
      );
      if (loc != null) _appendLocationMap(loc);
    } catch (e) {
      debugPrint('[TripTracker] Location sample skipped: $e');
    }
  }

  Future<void> _flushPendingAndObd() async {
    if (!_isRunning || _uploadInFlight) return;
    _uploadInFlight = true;
    try {
      while (_isRunning && _pendingPoints.isNotEmpty) {
        final targetTripId = _pendingPoints.first['_trip_id']?.toString() ?? _tripId;
        final batch = <Map<String, dynamic>>[];
        for (final pt in _pendingPoints) {
          if ((pt['_trip_id']?.toString() ?? _tripId) != targetTripId) break;
          batch.add({
            for (final e in pt.entries)
              if (e.key != '_trip_id') e.key: e.value,
          });
          if (batch.length >= 100) break;
        }
        if (batch.isEmpty) break;
        final ok = await _postBatch(targetTripId, batch);
        if (!ok) break;
        _pendingPoints.removeRange(0, batch.length);
        uploadedPointsNotifier.value += batch.length;
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
