import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'car_voice_assistant_service.dart';
import 'storage_service.dart';

/// Bridges native [NavitimeAccessibilityService] snapshots into Flutter,
/// provides live CAR NAVITIME context for AI Voice Assistant questions,
/// and proactively speaks concise Chinese lane & congestion alerts.
class NavitimeGuideService extends ChangeNotifier {
  static final NavitimeGuideService _instance =
      NavitimeGuideService._internal();
  factory NavitimeGuideService() => _instance;
  NavitimeGuideService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.myyaris.my_yaris/navitime_guide');
  static const String _prefAutoAnnounceKey = 'navitime_auto_announce_enabled';

  bool _initialized = false;
  bool _serviceRunning = false;
  bool _autoAnnounceEnabled = true;
  Map<String, dynamic>? _latestSnapshot;
  IStorageService? _storage;

  final Set<String> _announcedKeys = <String>{};
  DateTime? _lastAnnounceAt;
  String _lastAnnouncementText = '';

  bool get serviceRunning => _serviceRunning;
  bool get autoAnnounceEnabled => _autoAnnounceEnabled;
  Map<String, dynamic>? get latestSnapshot => _latestSnapshot;
  String get lastAnnouncementText => _lastAnnouncementText;

  Future<void> init(IStorageService storage) async {
    _storage = storage;
    if (_initialized) return;
    _initialized = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      _autoAnnounceEnabled = prefs.getBool(_prefAutoAnnounceKey) ?? true;
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

  Future<void> setAutoAnnounceEnabled(bool enabled) async {
    _autoAnnounceEnabled = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefAutoAnnounceKey, enabled);
    } catch (_) {}
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
    _serviceRunning = true;
    _latestSnapshot = raw;
    notifyListeners();

    if (_autoAnnounceEnabled) {
      _evaluateProactiveAnnouncement(raw);
    }
  }

  void _evaluateProactiveAnnouncement(Map<String, dynamic> snap) {
    final storage = _storage;
    if (storage == null) return;
    if (CarVoiceAssistantService().isBusy || CarVoiceAssistantService().isRecording) {
      return;
    }
    final now = DateTime.now();
    if (_lastAnnounceAt != null &&
        now.difference(_lastAnnounceAt!) < const Duration(seconds: 12)) {
      return;
    }

    final rawItems = snap['upcoming_intersections'];
    if (rawItems is! List || rawItems.isEmpty) return;

    // 1. Prioritize lane guidance for an approaching intersection (<= 1200m or <= 350m final cue)
    for (final item in rawItems) {
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
          meters <= 1200) {
        final bucket = meters <= 350 ? 'near' : 'approach';
        final key = 'lane:$name:$bucket:$laneSummary';
        if (!_announcedKeys.contains(key)) {
          _rememberKey(key);
          final distCn = formatDistanceChinese(meters);
          final trafficSuffix = traffic == 'congested'
              ? '，前方路段目前红色拥堵，请提前并线。'
              : (traffic == 'slow' ? '，前方略微缓行。' : '。');
          final place = name.isNotEmpty ? '到达$name' : '路口';
          final text = '前方$distCn$place，$laneSummary$trafficSuffix';
          _speak(storage, text);
          return;
        }
      }
    }

    // 2. Congestion alert for an upcoming segment within 3km
    for (final item in rawItems) {
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
          final text = '注意，前方$distCn处的$place目前$levelCn，请提前注意车速。';
          _speak(storage, text);
          return;
        }
      }
    }
  }

  void _rememberKey(String key) {
    if (_announcedKeys.length > 60) {
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
