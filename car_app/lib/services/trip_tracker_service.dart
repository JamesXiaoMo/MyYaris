import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/obd_telemetry.dart';
import 'backend_client.dart';
import 'car_obd_service.dart';

/// Samples GPS location from Android LocationManager every 10 seconds and
/// uploads batches to `/api/v1/trips/points` with in-memory offline buffering.
class TripTrackerService {
  static final TripTrackerService _instance = TripTrackerService._internal();
  factory TripTrackerService() => _instance;
  TripTrackerService._internal();

  static const MethodChannel _locationChannel =
      MethodChannel('com.myyaris.my_yaris/location');

  static const Duration sampleInterval = Duration(seconds: 10);
  static const int maxBufferedPoints = 500;

  final ValueNotifier<bool> isRunningNotifier = ValueNotifier(false);
  final ValueNotifier<int> uploadedPointsNotifier = ValueNotifier(0);

  Timer? _timer;
  bool _isRunning = false;
  bool _uploadInFlight = false;
  String _tripId = '';
  String _baseUrl = '';
  String _deviceId = '';
  String _token = '';
  Map<String, String> _fallbackDns = const {};
  final List<Map<String, dynamic>> _pendingPoints = [];

  bool get isRunning => _isRunning;
  String get tripId => _tripId;

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

    // Trigger an immediate sample shortly after startup, then every 10s.
    unawaited(_sampleAndUpload());
    _timer?.cancel();
    _timer = Timer.periodic(sampleInterval, (_) {
      unawaited(_sampleAndUpload());
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (!_isRunning) return;
    _isRunning = false;
    isRunningNotifier.value = false;
    try {
      await _locationChannel.invokeMethod<bool>('stopTracking');
    } catch (_) {}
  }

  Future<void> _sampleAndUpload() async {
    if (!_isRunning || _uploadInFlight) return;
    _uploadInFlight = true;
    try {
      Map<dynamic, dynamic>? loc;
      try {
        loc = await _locationChannel.invokeMethod<Map<dynamic, dynamic>>(
          'getLatestLocation',
        );
      } catch (e) {
        debugPrint('[TripTracker] Location sample skipped: $e');
      }

      if (loc != null) {
        final lat = (loc['latitude'] as num?)?.toDouble();
        final lon = (loc['longitude'] as num?)?.toDouble();
        if (lat != null &&
            lon != null &&
            lat.isFinite &&
            lon.isFinite &&
            !(lat == 0.0 && lon == 0.0) &&
            lat.abs() <= 90 &&
            lon.abs() <= 180) {
          final speedKmh = (loc['speed_kmh'] as num?)?.toDouble();
          final accuracyM = (loc['accuracy_m'] as num?)?.toDouble();
          final tsMs = (loc['timestamp_ms'] as num?)?.toInt();
          final recordedAt = (tsMs != null && tsMs > 0
                  ? DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true)
                  : DateTime.now().toUtc())
              .toIso8601String();

          _pendingPoints.add({
            'latitude': lat,
            'longitude': lon,
            if (speedKmh != null && speedKmh >= 0 && speedKmh <= 400)
              'speed_kmh': speedKmh,
            if (accuracyM != null && accuracyM >= 0 && accuracyM <= 5000)
              'accuracy_m': accuracyM,
            'recorded_at': recordedAt,
          });
          if (_pendingPoints.length > maxBufferedPoints) {
            _pendingPoints.removeRange(
              0,
              _pendingPoints.length - maxBufferedPoints,
            );
          }
        }
      }

      if (_pendingPoints.isNotEmpty) {
        final batch = List<Map<String, dynamic>>.from(
          _pendingPoints.take(100),
        );
        final ok = await _postBatch(batch);
        if (ok) {
          _pendingPoints.removeRange(0, batch.length);
          uploadedPointsNotifier.value += batch.length;
        }
      }

      await _uploadObdSnapshotIfReady();
    } finally {
      _uploadInFlight = false;
    }
  }

  Future<void> _uploadObdSnapshotIfReady() async {
    final telemetry = CarObdService().currentTelemetry;
    if (telemetry.status != ObdConnectionStatus.ready) return;
    try {
      final client = BackendClient(
        fallbackDns: _fallbackDns.isNotEmpty ? _fallbackDns : null,
      );
      try {
        await client.uploadVehicleTelemetry(
          baseUrl: _baseUrl,
          token: _token,
          deviceId: _deviceId,
          telemetry: telemetry.toJson(),
        );
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[TripTracker] OBD upload deferred: $e');
    }
  }

  Future<bool> _postBatch(List<Map<String, dynamic>> points) async {
    try {
      final uri = Uri.parse('$_baseUrl/api/v1/trips/points');
      if (uri.scheme != 'https' && uri.scheme != 'http') return false;
      final client = BackendClient(
        fallbackDns: _fallbackDns.isNotEmpty ? _fallbackDns : null,
      );
      try {
        return await client.uploadTripPoints(
          baseUrl: _baseUrl,
          token: _token,
          deviceId: _deviceId,
          tripId: _tripId,
          points: points,
        );
      } finally {
        client.close();
      }
    } catch (e) {
      debugPrint('[TripTracker] Upload batch deferred: $e');
      return false;
    }
  }
}
