import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'car_obd_service.dart';
import 'car_voice_assistant_service.dart';
import 'storage_service.dart';

enum NavitimeBroadcastMode {
  muted,
  laneAndTraffic,
  full;

  String get storageValue => switch (this) {
        NavitimeBroadcastMode.muted => 'muted',
        NavitimeBroadcastMode.laneAndTraffic => 'lane_and_traffic',
        NavitimeBroadcastMode.full => 'full',
      };

  String get label => switch (this) {
        NavitimeBroadcastMode.muted => '静音',
        NavitimeBroadcastMode.laneAndTraffic => '车道与拥堵',
        NavitimeBroadcastMode.full => '完整播报',
      };

  static NavitimeBroadcastMode fromStorage(String? raw) => switch (raw) {
        'muted' => NavitimeBroadcastMode.muted,
        'lane_and_traffic' => NavitimeBroadcastMode.laneAndTraffic,
        _ => NavitimeBroadcastMode.full,
      };
}

/// Bridges native [NavitimeAccessibilityService] snapshots into Flutter,
/// provides live CAR NAVITIME context + screenshot for AI Voice Assistant,
/// and proactively speaks speed-adaptive Chinese lane, turn, speed-limit,
/// congestion, and rest-area alerts.
class NavitimeGuideService extends ChangeNotifier {
  static final NavitimeGuideService _instance =
      NavitimeGuideService._internal();
  factory NavitimeGuideService() => _instance;
  NavitimeGuideService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.myyaris.my_yaris/navitime_guide');
  static const String _prefBroadcastModeKey = 'navitime_broadcast_mode';

  static final RegExp _restAreaPattern = RegExp(
    r'(SA|PA|サービスエリア|パーキング|道の駅|神明の里|休憩)',
    caseSensitive: false,
  );

  bool _initialized = false;
  bool _serviceRunning = false;
  NavitimeBroadcastMode _broadcastMode = NavitimeBroadcastMode.full;
  Map<String, dynamic>? _latestSnapshot;
  IStorageService? _storage;

  final Set<String> _announcedKeys = <String>{};
  DateTime? _lastAnnounceAt;
  DateTime? _driveStartedAt;
  DateTime? _lastSnapshotAt;
  String _lastAnnouncementText = '';

  int? _confirmedSpeedLimit;
  int? _candidateSpeedLimit;
  int _candidateSpeedLimitHits = 0;
  int _missingSpeedLimitFrames = 0;
  DateTime? _lastSpeedLimitSeenAt;
  DateTime? _lastOverspeedAlertAt;

  bool get serviceRunning => _serviceRunning;
  NavitimeBroadcastMode get broadcastMode => _broadcastMode;
  bool get autoAnnounceEnabled => _broadcastMode != NavitimeBroadcastMode.muted;
  Map<String, dynamic>? get latestSnapshot => _latestSnapshot;
  String get lastAnnouncementText => _lastAnnouncementText;
  int? get currentSpeedLimitKmh => _confirmedSpeedLimit;

  Future<void> init(IStorageService storage) async {
    _storage = storage;
    if (_initialized) return;
    _initialized = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _broadcastMode =
          NavitimeBroadcastMode.fromStorage(prefs.getString(_prefBroadcastModeKey));
    } catch (_) {}

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNavitimeSnapshot' && call.arguments is Map) {
        _handleSnapshot(Map<String, dynamic>.from(call.arguments as Map));
      }
    });

    await refreshStatus();
  }

  Future<void> refreshStatus() async {
    try {
      final status = await _channel.invokeMapMethod<String, dynamic>('getStatus');
      if (status != null) {
        _serviceRunning = status['running'] == true;
        final snap = status['snapshot'];
        if (snap is Map) {
          _latestSnapshot = Map<String, dynamic>.from(snap);
        }
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> openAccessibilitySettings() async {
    try {
      await _channel.invokeMethod<bool>('openAccessibilitySettings');
    } catch (_) {}
  }

  Future<Uint8List?> getLatestScreenshotJpeg() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('getLatestScreenshotJpeg');
      return (bytes != null && bytes.isNotEmpty) ? bytes : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> setBroadcastMode(NavitimeBroadcastMode mode) async {
    _broadcastMode = mode;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefBroadcastModeKey, mode.storageValue);
    } catch (_) {}
  }

  Future<void> setAutoAnnounceEnabled(bool enabled) async {
    await setBroadcastMode(
      enabled ? NavitimeBroadcastMode.full : NavitimeBroadcastMode.muted,
    );
  }

  /// Returns a fresh snapshot (within last 30s) suitable for attaching to AI voice prompts.
  Map<String, dynamic>? buildVoiceContext() {
    final snap = _latestSnapshot;
    if (snap == null) return null;
    final ts = snap['timestamp_ms'];
    if (ts is num) {
      final ageMs = DateTime.now().millisecondsSinceEpoch - ts.toInt();
      if (ageMs > 30000) return null;
    }
    return snap;
  }

  void _handleSnapshot(Map<String, dynamic> raw) {
    final now = DateTime.now();
    // Reset fatigue timer & stale speed limit after a >= 15-minute driving break
    if (_lastSnapshotAt != null &&
        now.difference(_lastSnapshotAt!) >= const Duration(minutes: 15)) {
      _driveStartedAt = now;
      _confirmedSpeedLimit = null;
      _announcedKeys.clear();
    } else {
      _driveStartedAt ??= now;
    }
    _lastSnapshotAt = now;
    _serviceRunning = true;
    _latestSnapshot = raw;
    _updateSpeedLimitTracker(raw, now);
    notifyListeners();

    if (_broadcastMode != NavitimeBroadcastMode.muted) {
      _evaluateProactiveAnnouncement(raw);
    }
  }

  double _currentSpeedKmh() {
    final spd = CarObdService().telemetryNotifier.value.speedKmh;
    if (spd != null && spd.isFinite && spd >= 0) return spd.toDouble();
    return 45.0;
  }

  void _updateSpeedLimitTracker(Map<String, dynamic> snap, DateTime now) {
    final rawLimit = snap['speed_limit_kmh'];
    if (rawLimit is! num) {
      _missingSpeedLimitFrames++;
      if (_missingSpeedLimitFrames >= 6 ||
          (_lastSpeedLimitSeenAt != null &&
              now.difference(_lastSpeedLimitSeenAt!) >=
                  const Duration(seconds: 90))) {
        _confirmedSpeedLimit = null;
        _candidateSpeedLimit = null;
        _candidateSpeedLimitHits = 0;
      }
      return;
    }
    final limit = rawLimit.toInt();
    if (limit < 20 || limit > 120) return;

    _missingSpeedLimitFrames = 0;
    _lastSpeedLimitSeenAt = now;

    if (limit == _candidateSpeedLimit) {
      _candidateSpeedLimitHits++;
    } else {
      _candidateSpeedLimit = limit;
      _candidateSpeedLimitHits = 1;
    }

    // Require 2 consecutive matching frames to eliminate sign-transition noise
    if (_candidateSpeedLimitHits >= 2 && limit != _confirmedSpeedLimit) {
      final prev = _confirmedSpeedLimit;
      _confirmedSpeedLimit = limit;
      if (_broadcastMode == NavitimeBroadcastMode.full &&
          prev != null &&
          limit < prev) {
        final storage = _storage;
        if (storage != null && _canAnnounceNow()) {
          _speak(storage, '注意，前方限速降为$limit，请注意减速。');
        }
      }
    }
  }

  bool _canAnnounceNow() {
    if (CarVoiceAssistantService().isBusy || CarVoiceAssistantService().isRecording) {
      return false;
    }
    final now = DateTime.now();
    if (_lastAnnounceAt != null &&
        now.difference(_lastAnnounceAt!) < const Duration(seconds: 12)) {
      return false;
    }
    return true;
  }

  void _evaluateProactiveAnnouncement(Map<String, dynamic> snap) {
    final storage = _storage;
    if (storage == null || !_canAnnounceNow()) return;

    final speedKmh = _currentSpeedKmh();
    final isHighwaySpeed = speedKmh >= 65.0;
    final approachMeters = isHighwaySpeed ? 1500 : 850;
    final finalMeters = isHighwaySpeed ? 500 : 280;

    final nextDestName = (snap['next_destination_name'] ?? '').toString().trim();
    final nextDestDistText = (snap['next_destination_distance'] ?? '').toString().trim();
    final nextDestMeters = parseDistanceMeters(nextDestDistText);
    final nextTurnDir = (snap['next_turn_direction'] ?? '').toString().trim();
    final twoAheadDistText = (snap['two_ahead_distance'] ?? '').toString().trim();
    final twoAheadMeters = parseDistanceMeters(twoAheadDistText);
    final twoAheadDir = (snap['two_ahead_direction'] ?? '').toString().trim();

    final rawItems = snap['upcoming_intersections'];
    final items = rawItems is List ? rawItems : const [];

    // 1. Lane guidance alert (speed-adaptive thresholds)
    for (final item in items) {
      if (item is! Map) continue;
      final name = (item['inter_name'] ?? '').toString().trim();
      final distText = (item['distance_text'] ?? '').toString().trim();
      final meters = parseDistanceMeters(distText);
      final laneSummary = (item['lane_summary'] ?? '').toString().trim();
      final recLanes = item['recommended_lanes'];
      final traffic = (item['traffic'] ?? 'unknown').toString();

      if (laneSummary.isNotEmpty &&
          recLanes is List &&
          recLanes.isNotEmpty &&
          meters != null &&
          meters <= approachMeters) {
        final bucket = meters <= finalMeters ? 'near' : 'approach';
        final key = 'lane:$name:$bucket:$laneSummary';
        if (!_announcedKeys.contains(key)) {
          _rememberKey(key);
          final distCn = formatDistanceChinese(meters);
          final turnHint = (name.isNotEmpty &&
                  name == nextDestName &&
                  nextTurnDir.isNotEmpty &&
                  nextTurnDir != '直行')
              ? nextTurnDir
              : '';
          final twoAheadHint = (bucket == 'near' &&
                  twoAheadMeters != null &&
                  twoAheadMeters <= 300 &&
                  twoAheadDir.isNotEmpty &&
                  twoAheadDir != '直行')
              ? '，拐过去${formatDistanceChinese(twoAheadMeters)}后马上还有一次$twoAheadDir'
              : '';
          final trafficHint = traffic == 'congested'
              ? '，前方红色拥堵请提前并线'
              : (traffic == 'slow' ? '，前方略微缓行' : '');
          final place = name.isNotEmpty ? '到达$name' : '路口';
          final text = '前方$distCn$place$turnHint，$laneSummary$twoAheadHint$trafficHint。';
          _speak(storage, text);
          return;
        }
      }
    }

    // 2. Full mode: Major turn / highway ramp + continuous two-ahead turn alert
    if (_broadcastMode == NavitimeBroadcastMode.full &&
        nextDestMeters != null &&
        nextDestMeters <= approachMeters &&
        nextTurnDir.isNotEmpty &&
        nextTurnDir != '直行') {
      final bucket = nextDestMeters <= finalMeters ? 'near' : 'approach';
      final key = 'turn:$nextDestName:$bucket:$nextTurnDir';
      if (!_announcedKeys.contains(key)) {
        _rememberKey(key);
        final distCn = formatDistanceChinese(nextDestMeters);
        final place = nextDestName.isNotEmpty ? '在$nextDestName' : '';
        final twoAheadHint = (bucket == 'near' &&
                twoAheadMeters != null &&
                twoAheadMeters <= 300 &&
                twoAheadDir.isNotEmpty &&
                twoAheadDir != '直行')
            ? '，之后${formatDistanceChinese(twoAheadMeters)}马上还有一次$twoAheadDir'
            : '';
        _speak(storage, '前方$distCn$place$nextTurnDir$twoAheadHint。');
        return;
      }
    }

    // 3. Congestion alert within 3km
    for (final item in items) {
      if (item is! Map) continue;
      final name = (item['inter_name'] ?? '').toString().trim();
      final distText = (item['distance_text'] ?? '').toString().trim();
      final meters = parseDistanceMeters(distText);
      final traffic = (item['traffic'] ?? 'unknown').toString();
      if ((traffic == 'congested' || traffic == 'slow') &&
          meters != null &&
          meters <= 3000) {
        final key = 'traffic:$name:$traffic';
        if (!_announcedKeys.contains(key)) {
          _rememberKey(key);
          final distCn = formatDistanceChinese(meters);
          final place = name.isNotEmpty ? '$name附近' : '前方路段';
          final levelCn = traffic == 'congested' ? '红色拥堵' : '橙色缓行';
          _speak(storage, '注意，前方$distCn处的$place目前$levelCn，请提前注意车速。');
          return;
        }
      }
    }

    // 4. Low fuel (<20%) or fatigue (>=2h) + upcoming SA/PA/道の駅 alert
    final fuelPct = CarObdService().telemetryNotifier.value.fuelLevelPercent;
    final lowFuel = fuelPct != null && fuelPct < 20.0;
    final fatigue = _driveStartedAt != null &&
        DateTime.now().difference(_driveStartedAt!) >= const Duration(hours: 2);
    if (lowFuel || fatigue) {
      for (final item in items) {
        if (item is! Map) continue;
        final name = (item['inter_name'] ?? '').toString().trim();
        final distText = (item['distance_text'] ?? '').toString().trim();
        final meters = parseDistanceMeters(distText);
        if (name.isNotEmpty &&
            _restAreaPattern.hasMatch(name) &&
            meters != null &&
            meters <= 5000) {
          final reason = lowFuel ? 'fuel' : 'fatigue';
          final key = 'rest:$name:$reason';
          if (!_announcedKeys.contains(key)) {
            _rememberKey(key);
            final distCn = formatDistanceChinese(meters);
            final msg = lowFuel
                ? '当前油量偏低，前方$distCn有$name，建议顺路补油休息。'
                : '您已连续驾驶超过两小时，前方$distCn有$name，建议进站休息一下。';
            _speak(storage, msg);
            return;
          }
        }
      }
    }

    // 5. Full mode: Gentle overspeed alert (+12 km/h over confirmed limit, 60s cooldown)
    final limit = _confirmedSpeedLimit;
    if (_broadcastMode == NavitimeBroadcastMode.full &&
        limit != null &&
        CarObdService().telemetryNotifier.value.speedKmh != null &&
        speedKmh >= limit + 12.0) {
      final now = DateTime.now();
      if (_lastOverspeedAlertAt == null ||
          now.difference(_lastOverspeedAlertAt!) >= const Duration(seconds: 60)) {
        _lastOverspeedAlertAt = now;
        _speak(storage, '当前车速偏快，本路段限速$limit，请注意控制车速。');
      }
    }
  }

  void _rememberKey(String key) {
    if (_announcedKeys.length > 80) {
      _announcedKeys.clear();
    }
    _announcedKeys.add(key);
  }

  void _speak(IStorageService storage, String text) {
    _lastAnnounceAt = DateTime.now();
    _lastAnnouncementText = text;
    notifyListeners();
    debugPrint('[NavitimeGuide] Proactive Chinese alert: $text');
    unawaited(CarVoiceAssistantService().speakAnnouncement(storage, text));
  }

  static int? parseDistanceMeters(String raw) {
    final s = raw.trim().toLowerCase().replaceAll(',', '');
    if (s.isEmpty) return null;
    final kmMatch = RegExp(r'^(\d+(?:\.\d+)?)\s*km$').firstMatch(s);
    if (kmMatch != null) {
      final v = double.tryParse(kmMatch.group(1)!);
      return v != null ? (v * 1000).round() : null;
    }
    final mMatch = RegExp(r'^(\d+(?:\.\d+)?)\s*m$').firstMatch(s);
    if (mMatch != null) {
      final v = double.tryParse(mMatch.group(1)!);
      return v?.round();
    }
    return null;
  }

  static String formatDistanceChinese(int meters) {
    if (meters >= 1000) {
      final km = (meters / 1000.0);
      return km >= 10 ? '${km.round()}公里' : '${km.toStringAsFixed(1)}公里';
    }
    final rounded = ((meters + 25) ~/ 50) * 50;
    return '${rounded < 50 ? meters : rounded}米';
  }
}
