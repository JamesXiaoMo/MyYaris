import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'built_in_player_service.dart';
import 'navitime_guide_service.dart';
import 'storage_service.dart';

enum VoiceAssistantState {
  idle,
  recording,
  thinking,
  speaking,
  error,
}

class VoicePlaceCandidate {
  final String name;
  final String address;
  final double lat;
  final double lng;
  final double? rating;
  final double? distanceKm;

  const VoicePlaceCandidate({
    required this.name,
    required this.address,
    required this.lat,
    required this.lng,
    this.rating,
    this.distanceKm,
  });

  factory VoicePlaceCandidate.fromJson(Map<String, dynamic> json) {
    return VoicePlaceCandidate(
      name: (json['name'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
      lat: (json['lat'] is num) ? (json['lat'] as num).toDouble() : 0.0,
      lng: (json['lng'] is num) ? (json['lng'] as num).toDouble() : 0.0,
      rating: (json['rating'] is num) ? (json['rating'] as num).toDouble() : null,
      distanceKm: (json['distance_km'] is num)
          ? (json['distance_km'] as num).toDouble()
          : null,
    );
  }
}

class CarVoiceAssistantService extends ChangeNotifier {
  static final CarVoiceAssistantService _instance =
      CarVoiceAssistantService._internal();
  factory CarVoiceAssistantService() => _instance;
  CarVoiceAssistantService._internal();

  static const MethodChannel _voiceChannel =
      MethodChannel('com.myyaris.my_yaris/voice');
  static const MethodChannel _locationChannel =
      MethodChannel('com.myyaris.my_yaris/location');
  static const String _prefWakeWordEnabled = 'myyaris_wake_word_enabled';
  static const String _prefStartupBriefingEnabled = 'myyaris_startup_briefing_enabled';
  static const String _prefLastBriefingMs = 'myyaris_last_briefing_ms';

  IStorageService? _storage;
  bool _wakeWordInitialized = false;
  bool _briefingScheduled = false;
  final ValueNotifier<bool> wakeWordEnabledNotifier = ValueNotifier<bool>(true);
  final ValueNotifier<bool> wakeWordListeningNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<bool> startupBriefingEnabledNotifier = ValueNotifier<bool>(true);
  String? _wakeWordNote;

  VoiceAssistantState _state = VoiceAssistantState.idle;
  String _statusText = '';
  String _transcript = '';
  String _replyText = '';
  List<VoicePlaceCandidate> _candidates = const [];
  bool _bannerVisible = false;
  Timer? _autoStopTimer;
  Timer? _bannerDismissTimer;

  VoiceAssistantState get state => _state;
  String get statusText => _statusText;
  String get transcript => _transcript;
  String get replyText => _replyText;
  List<VoicePlaceCandidate> get candidates => _candidates;
  bool get bannerVisible => _bannerVisible;
  bool get wakeWordEnabled => wakeWordEnabledNotifier.value;
  bool get wakeWordListening => wakeWordListeningNotifier.value;
  bool get startupBriefingEnabled => startupBriefingEnabledNotifier.value;
  String? get wakeWordNote => _wakeWordNote;

  bool get isRecording => _state == VoiceAssistantState.recording;
  bool get isBusy =>
      _state == VoiceAssistantState.thinking ||
      _state == VoiceAssistantState.speaking;

  /// Initializes offline "Hey Yaris" wake-word listener and native voice callbacks.
  Future<void> initWakeWord(IStorageService storage) async {
    _storage = storage;
    if (_wakeWordInitialized) return;
    _wakeWordInitialized = true;
    _voiceChannel.setMethodCallHandler(_handleNativeVoiceCall);
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getBool(_prefWakeWordEnabled) ?? true;
      wakeWordEnabledNotifier.value = saved;
      startupBriefingEnabledNotifier.value =
          prefs.getBool(_prefStartupBriefingEnabled) ?? true;
      await _syncWakeWordToNative(saved);
    } catch (e) {
      debugPrint('[VoiceAssistant] initWakeWord note: $e');
    }
  }

  Future<void> setStartupBriefingEnabled(bool enabled) async {
    startupBriefingEnabledNotifier.value = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefStartupBriefingEnabled, enabled);
    } catch (_) {}
  }

  /// Speaks a concise Chinese startup briefing once per drive (30-min cooldown)
  /// after network and GPS settle.
  Future<void> maybeSpeakStartupBriefing(IStorageService storage) async {
    _storage = storage;
    if (_briefingScheduled) return;
    _briefingScheduled = true;

    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_prefStartupBriefingEnabled) ?? true;
      startupBriefingEnabledNotifier.value = enabled;
      if (!enabled) return;

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final lastMs = prefs.getInt(_prefLastBriefingMs) ?? 0;
      if (lastMs > 0 && (nowMs - lastMs) < const Duration(minutes: 30).inMilliseconds) {
        return;
      }

      // Wait ~8s for Tailscale / GPS / OBD startup handshake to settle
      await Future<void>.delayed(const Duration(seconds: 8));
      if (!startupBriefingEnabledNotifier.value || isBusy || isRecording) return;

      final baseUrl = _normalizeBaseUrl(storage.backendUrl);
      if (baseUrl.isEmpty || storage.carToken.trim().isEmpty) return;

      final loc = await _tryGetLastGps();
      final uri = Uri.parse('$baseUrl/api/v1/assistant/briefing');
      final payload = utf8.encode(
        jsonEncode({
          'device_id': storage.deviceId,
          'lat': ?loc?.$1,
          'lng': ?loc?.$2,
        }),
      );
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
      try {
        final req = await client.postUrl(uri).timeout(const Duration(seconds: 8));
        req.headers.set('Authorization', 'Bearer ${storage.carToken}');
        req.headers.set('X-Device-Token', storage.carToken);
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        req.add(payload);
        final resp = await req.close().timeout(const Duration(seconds: 12));
        final raw = await resp.transform(utf8.decoder).join();
        if (resp.statusCode < 200 || resp.statusCode >= 300) return;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return;
        final data = Map<String, dynamic>.from(decoded);
        final reply = (data['reply_text'] ?? '').toString().trim();
        if (reply.isEmpty || isBusy || isRecording) return;

        await prefs.setInt(_prefLastBriefingMs, DateTime.now().millisecondsSinceEpoch);
        await _applyAssistantResponse(data, storage: storage);
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      debugPrint('[VoiceAssistant] Startup briefing skipped: $e');
    }
  }

  Future<void> setWakeWordEnabled(bool enabled) async {
    wakeWordEnabledNotifier.value = enabled;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefWakeWordEnabled, enabled);
    } catch (_) {}
    await _syncWakeWordToNative(enabled);
  }

  Future<void> _syncWakeWordToNative(bool enabled) async {
    try {
      final res = await _voiceChannel.invokeMapMethod<String, dynamic>(
        'setWakeWordEnabled',
        {'enabled': enabled},
      );
      final listening = res?['listening'] == true;
      final err = res?['lastError']?.toString();
      wakeWordListeningNotifier.value = listening;
      _wakeWordNote = (err != null && err.isNotEmpty) ? err : null;
      notifyListeners();
    } catch (e) {
      wakeWordListeningNotifier.value = false;
      _wakeWordNote = '$e';
      notifyListeners();
    }
  }

  Future<void> _pauseWakeWord() async {
    if (!wakeWordEnabledNotifier.value) return;
    try {
      await _voiceChannel.invokeMethod('pauseWakeWord');
      wakeWordListeningNotifier.value = false;
    } catch (_) {}
  }

  Future<void> _resumeWakeWord() async {
    if (!wakeWordEnabledNotifier.value) return;
    try {
      await _voiceChannel.invokeMethod('resumeWakeWord');
      final status = await _voiceChannel.invokeMapMethod<String, dynamic>('getWakeWordStatus');
      wakeWordListeningNotifier.value = status?['listening'] == true;
      notifyListeners();
    } catch (_) {}
  }

  Future<dynamic> _handleNativeVoiceCall(MethodCall call) async {
    switch (call.method) {
      case 'onWakeWordDetected':
        final storage = _storage;
        if (storage == null || isBusy || isRecording) {
          unawaited(_resumeWakeWord());
          return;
        }
        wakeWordListeningNotifier.value = false;
        unawaited(_startRecording(storage, autoStopOnSilence: true));
        return;
      case 'onAutoRecordingComplete':
        if (_state != VoiceAssistantState.recording) return;
        _autoStopTimer?.cancel();
        final args = call.arguments is Map
            ? Map<String, dynamic>.from(call.arguments as Map)
            : const <String, dynamic>{};
        final wavPath = (args['wavPath'] ?? '').toString().trim();
        final speechDetected = args['speechDetected'] == true;
        final storage = _storage;
        if (storage == null || !speechDetected || wavPath.isEmpty) {
          await BuiltInPlayerService().restoreMusicVolume();
          _state = VoiceAssistantState.idle;
          _statusText = '已唤醒但未听到指令';
          _bannerVisible = true;
          notifyListeners();
          _bannerDismissTimer?.cancel();
          _bannerDismissTimer = Timer(const Duration(seconds: 3), () {
            if (_state == VoiceAssistantState.idle) {
              _bannerVisible = false;
              notifyListeners();
            }
          });
          unawaited(_resumeWakeWord());
          return;
        }
        unawaited(_submitWavPath(storage, wavPath));
        return;
      case 'onMicPermissionGranted':
        if (wakeWordEnabledNotifier.value) {
          unawaited(_syncWakeWordToNative(true));
        }
        return;
    }
  }

  void dismissBanner() {
    _bannerDismissTimer?.cancel();
    _bannerVisible = false;
    if (_state == VoiceAssistantState.error) {
      _state = VoiceAssistantState.idle;
    }
    notifyListeners();
  }

  Future<void> toggleVoice(IStorageService storage) async {
    if (_state == VoiceAssistantState.recording) {
      await _stopAndSubmit(storage);
      return;
    }
    if (isBusy) return;
    await _startRecording(storage);
  }

  Future<void> _startRecording(
    IStorageService storage, {
    bool autoStopOnSilence = false,
  }) async {
    _storage = storage;
    final baseUrl = _normalizeBaseUrl(storage.backendUrl);
    if (baseUrl.isEmpty || storage.carToken.trim().isEmpty) {
      _setError('请先在设置页配置后端地址和车机令牌');
      unawaited(_resumeWakeWord());
      return;
    }

    _bannerDismissTimer?.cancel();
    _autoStopTimer?.cancel();

    // Pause wake-word engine & lower music volume immediately
    await _pauseWakeWord();
    await BuiltInPlayerService().duckForVoiceInput();

    try {
      final res = await _voiceChannel.invokeMethod<String>(
        'startRecording',
        {'autoStopOnSilence': autoStopOnSilence},
      );
      if (res == 'PERMISSION_REQUESTED') {
        await BuiltInPlayerService().restoreMusicVolume();
        _setError('请先允许麦克风权限，然后再次点击「语音」');
        return;
      }
      _state = VoiceAssistantState.recording;
      _statusText = autoStopOnSilence
          ? 'Hey Yaris 已唤醒 · 请直接说指令…'
          : '正在聆听… 说完再点一次左侧「结束」';
      _transcript = '';
      _replyText = '';
      _bannerVisible = true;
      notifyListeners();

      // Safety auto-stop after 10 seconds
      _autoStopTimer = Timer(const Duration(seconds: 10), () {
        if (_state == VoiceAssistantState.recording) {
          unawaited(_stopAndSubmit(storage));
        }
      });
    } catch (e) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('麦克风启动失败：$e');
      unawaited(_resumeWakeWord());
    }
  }

  Future<void> _stopAndSubmit(IStorageService storage) async {
    _autoStopTimer?.cancel();
    _state = VoiceAssistantState.thinking;
    _statusText = '正在识别并思考…';
    _bannerVisible = true;
    notifyListeners();

    String? wavPath;
    try {
      wavPath = await _voiceChannel.invokeMethod<String>('stopRecording');
    } catch (e) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('录音保存失败：$e');
      unawaited(_resumeWakeWord());
      return;
    }

    if (wavPath == null || wavPath.trim().isEmpty) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('录音太短，请说完指令后再结束');
      unawaited(_resumeWakeWord());
      return;
    }

    await _submitWavPath(storage, wavPath);
  }

  Future<void> _submitWavPath(IStorageService storage, String wavPath) async {
    _autoStopTimer?.cancel();
    _state = VoiceAssistantState.thinking;
    _statusText = '正在识别并思考…';
    _bannerVisible = true;
    notifyListeners();

    try {
      final wavFile = File(wavPath);
      final wavBytes = await wavFile.readAsBytes();
      final loc = await _tryGetLastGps();
      final respJson = await _uploadVoiceWav(
        storage: storage,
        wavBytes: wavBytes,
        lat: loc?.$1,
        lng: loc?.$2,
      );
      await _applyAssistantResponse(respJson, storage: storage);
    } catch (e) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('AI 助手连接失败：$e');
      unawaited(_resumeWakeWord());
    }
  }

  /// Speaks a proactive Chinese navigation/safety announcement using backend edge-tts
  /// with automatic instant fallback to offline Android Chinese TTS (for tunnels/offline).
  Future<void> speakAnnouncement(IStorageService storage, String text) async {
    final clean = text.trim();
    if (clean.isEmpty || isBusy || isRecording) return;

    _state = VoiceAssistantState.speaking;
    _statusText = '导航中文播报';
    _replyText = clean;
    _bannerVisible = true;
    notifyListeners();

    await _pauseWakeWord();
    await BuiltInPlayerService().duckForVoiceInput();
    var playedCloud = false;
    final baseUrl = _normalizeBaseUrl(storage.backendUrl);
    if (baseUrl.isNotEmpty && storage.carToken.trim().isNotEmpty) {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
      try {
        final uri = Uri.parse('$baseUrl/api/v1/assistant/tts');
        final req = await client.postUrl(uri).timeout(const Duration(seconds: 4));
        req.headers.set('Authorization', 'Bearer ${storage.carToken}');
        req.headers.set('X-Device-Token', storage.carToken);
        req.headers.set('Content-Type', 'application/json; charset=utf-8');
        req.add(utf8.encode(jsonEncode({'text': clean})));
        final resp = await req.close().timeout(const Duration(seconds: 6));
        final raw = await resp.transform(utf8.decoder).join();
        if (resp.statusCode >= 200 && resp.statusCode < 300) {
          final decoded = jsonDecode(raw);
          final ttsUrl =
              decoded is Map ? (decoded['tts_url'] ?? '').toString().trim() : '';
          if (ttsUrl.isNotEmpty) {
            playedCloud = await BuiltInPlayerService().playVoiceReply(
              ttsUrl,
              baseUrl: baseUrl,
              token: storage.carToken,
            );
          }
        }
      } catch (e) {
        debugPrint('[VoiceAssistant] Cloud TTS unavailable, switching to offline TTS: $e');
      } finally {
        client.close(force: true);
      }
    }

    if (!playedCloud) {
      try {
        await _voiceChannel
            .invokeMethod<bool>('speakOfflineTts', {
              'text': clean,
              'volume': BuiltInPlayerService().aiVoiceVolume,
            })
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('[VoiceAssistant] Offline TTS note: $e');
      } finally {
        await BuiltInPlayerService().restoreMusicVolume();
      }
    }

    if (_state == VoiceAssistantState.speaking) {
      _state = VoiceAssistantState.idle;
      _statusText = '已完成';
      notifyListeners();
      _bannerDismissTimer?.cancel();
      _bannerDismissTimer = Timer(const Duration(seconds: 6), () {
        if (_state == VoiceAssistantState.idle) {
          _bannerVisible = false;
          notifyListeners();
        }
      });
    }
    unawaited(_resumeWakeWord());
  }

  Future<void> selectCandidate(IStorageService storage, int oneBasedIndex) async {
    if (isBusy || _state == VoiceAssistantState.recording) return;
    _bannerDismissTimer?.cancel();
    _state = VoiceAssistantState.thinking;
    _statusText = '正在为你发送第 $oneBasedIndex 家导航…';
    _bannerVisible = true;
    notifyListeners();

    try {
      final loc = await _tryGetLastGps();
      final respJson = await _sendTextCommand(
        storage: storage,
        text: '去第$oneBasedIndex家',
        lat: loc?.$1,
        lng: loc?.$2,
      );
      await _applyAssistantResponse(respJson, storage: storage);
    } catch (e) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('选点失败：$e');
    }
  }

  Future<void> _applyAssistantResponse(
    Map<String, dynamic> data, {
    IStorageService? storage,
  }) async {
    final effectiveStorage = storage ?? _storage;
    _transcript = (data['transcript'] ?? '').toString().trim();
    _replyText = (data['reply_text'] ?? '').toString().trim();
    final rawCands = data['candidates'];
    if (rawCands is List && rawCands.isNotEmpty) {
      _candidates = rawCands
          .whereType<Map>()
          .map((e) => VoicePlaceCandidate.fromJson(Map<String, dynamic>.from(e)))
          .toList(growable: false);
    } else {
      _candidates = const [];
    }

    // Execute optional local client action (volume adjustment, SD-card cache)
    final rawAction = data['client_action'];
    if (rawAction is Map) {
      final actionMap = Map<String, dynamic>.from(rawAction);
      final actionType = (actionMap['type'] ?? '').toString().trim();
      if (actionType == 'adjust_volume') {
        final target = (actionMap['target'] ?? 'music').toString().trim();
        final delta = (actionMap['delta'] is num)
            ? (actionMap['delta'] as num).toDouble()
            : 0.0;
        if (target == 'ai') {
          await BuiltInPlayerService().setAiVoiceVolume(
            (BuiltInPlayerService().aiVoiceVolume + delta).clamp(0.1, 1.0),
          );
        } else {
          await BuiltInPlayerService().setVolume(
            (BuiltInPlayerService().currentVolume + delta).clamp(0.05, 1.0),
          );
        }
      } else if (actionType == 'cache_current' && effectiveStorage != null) {
        unawaited(
          BuiltInPlayerService().cacheCurrentTrackNow(
            baseUrl: _normalizeBaseUrl(effectiveStorage.backendUrl),
            token: effectiveStorage.carToken,
          ),
        );
      }
    }

    final ttsUrl = (data['tts_url'] ?? '').toString().trim();
    var playedCloud = false;
    if (ttsUrl.isNotEmpty) {
      await _pauseWakeWord();
      _state = VoiceAssistantState.speaking;
      _statusText = 'AI 语音播报中…';
      _bannerVisible = true;
      notifyListeners();
      playedCloud = await BuiltInPlayerService().playVoiceReply(
        ttsUrl,
        baseUrl: effectiveStorage != null
            ? _normalizeBaseUrl(effectiveStorage.backendUrl)
            : null,
        token: effectiveStorage?.carToken,
      );
    }
    if (!playedCloud && _replyText.isNotEmpty) {
      await _pauseWakeWord();
      await BuiltInPlayerService().duckForVoiceInput();
      try {
        await _voiceChannel
            .invokeMethod<bool>('speakOfflineTts', {
              'text': _replyText,
              'volume': BuiltInPlayerService().aiVoiceVolume,
            })
            .timeout(const Duration(seconds: 12));
      } catch (e) {
        debugPrint('[VoiceAssistant] Offline fallback TTS note: $e');
      } finally {
        await BuiltInPlayerService().restoreMusicVolume();
      }
    } else if (!playedCloud) {
      await BuiltInPlayerService().restoreMusicVolume();
    }

    _state = VoiceAssistantState.idle;
    _statusText = _candidates.isNotEmpty ? '可直接点击下方地点，或说「Hey Yaris」选第几家' : '已完成';
    _bannerVisible = true;
    notifyListeners();
    unawaited(_resumeWakeWord());

    // Auto-hide banner after 8s if no pending candidates (or 45s if candidates wait)
    _bannerDismissTimer?.cancel();
    _bannerDismissTimer = Timer(
      Duration(seconds: _candidates.isNotEmpty ? 45 : 8),
      () {
        if (_state == VoiceAssistantState.idle) {
          _bannerVisible = false;
          notifyListeners();
        }
      },
    );
  }

  void _setError(String msg) {
    _state = VoiceAssistantState.error;
    _statusText = msg;
    _bannerVisible = true;
    notifyListeners();
    _bannerDismissTimer?.cancel();
    _bannerDismissTimer = Timer(const Duration(seconds: 6), () {
      if (_state == VoiceAssistantState.error) {
        _state = VoiceAssistantState.idle;
        _bannerVisible = false;
        notifyListeners();
      }
    });
  }

  String _normalizeBaseUrl(String raw) {
    var s = raw.trim();
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  Future<(double, double)?> _tryGetLastGps() async {
    try {
      final map = await _locationChannel
          .invokeMapMethod<String, dynamic>('getLastKnownLocation')
          .timeout(const Duration(milliseconds: 600));
      if (map == null) return null;
      final lat = map['lat'] ?? map['latitude'];
      final lng = map['lng'] ?? map['longitude'];
      if (lat is num && lng is num && !(lat == 0 && lng == 0)) {
        return (lat.toDouble(), lng.toDouble());
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>> _uploadVoiceWav({
    required IStorageService storage,
    required Uint8List wavBytes,
    double? lat,
    double? lng,
  }) async {
    final baseUrl = _normalizeBaseUrl(storage.backendUrl);
    final uri = Uri.parse('$baseUrl/api/v1/assistant/voice');
    final boundary = '----MyYarisVoice${DateTime.now().millisecondsSinceEpoch}';
    final bodyBuilder = BytesBuilder();

    void addField(String name, String value) {
      bodyBuilder.add(utf8.encode('--$boundary\r\n'));
      bodyBuilder.add(
        utf8.encode('Content-Disposition: form-data; name="$name"\r\n\r\n'),
      );
      bodyBuilder.add(utf8.encode('$value\r\n'));
    }

    addField('device_id', storage.deviceId);
    if (lat != null && lng != null) {
      addField('lat', lat.toStringAsFixed(6));
      addField('lng', lng.toStringAsFixed(6));
    }
    final navCtx = NavitimeGuideService().buildVoiceContext();
    if (navCtx != null) {
      addField('navitime_context', jsonEncode(navCtx));
      final screenJpeg = await NavitimeGuideService().getLatestScreenshotJpeg();
      if (screenJpeg != null && screenJpeg.isNotEmpty) {
        bodyBuilder.add(utf8.encode('--$boundary\r\n'));
        bodyBuilder.add(
          utf8.encode(
            'Content-Disposition: form-data; name="navitime_screenshot"; filename="navitime.jpg"\r\n'
            'Content-Type: image/jpeg\r\n\r\n',
          ),
        );
        bodyBuilder.add(screenJpeg);
        bodyBuilder.add(utf8.encode('\r\n'));
      }
    }

    bodyBuilder.add(utf8.encode('--$boundary\r\n'));
    bodyBuilder.add(
      utf8.encode(
        'Content-Disposition: form-data; name="audio"; filename="voice.wav"\r\n'
        'Content-Type: audio/wav\r\n\r\n',
      ),
    );
    bodyBuilder.add(wavBytes);
    bodyBuilder.add(utf8.encode('\r\n--$boundary--\r\n'));

    final payload = bodyBuilder.takeBytes();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 25));
      req.headers.set('Authorization', 'Bearer ${storage.carToken}');
      req.headers.set('X-Device-Token', storage.carToken);
      req.headers.set('Content-Type', 'multipart/form-data; boundary=$boundary');
      req.headers.set('Content-Length', payload.length.toString());
      req.add(payload);
      final resp = await req.close().timeout(const Duration(seconds: 30));
      final rawText = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $rawText');
      }
      final parsed = jsonDecode(rawText);
      return parsed is Map ? Map<String, dynamic>.from(parsed) : <String, dynamic>{};
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _sendTextCommand({
    required IStorageService storage,
    required String text,
    double? lat,
    double? lng,
  }) async {
    final baseUrl = _normalizeBaseUrl(storage.backendUrl);
    final uri = Uri.parse('$baseUrl/api/v1/assistant/text');
    final navCtx = NavitimeGuideService().buildVoiceContext();
    final payload = utf8.encode(
      jsonEncode({
        'text': text,
        'device_id': storage.deviceId,
        'lat': ?lat,
        'lng': ?lng,
        'navitime_context': ?navCtx,
      }),
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 20));
      req.headers.set('Authorization', 'Bearer ${storage.carToken}');
      req.headers.set('X-Device-Token', storage.carToken);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(payload);
      final resp = await req.close().timeout(const Duration(seconds: 25));
      final rawText = await resp.transform(utf8.decoder).join();
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw HttpException('HTTP ${resp.statusCode}: $rawText');
      }
      final parsed = jsonDecode(rawText);
      return parsed is Map ? Map<String, dynamic>.from(parsed) : <String, dynamic>{};
    } finally {
      client.close(force: true);
    }
  }
}
