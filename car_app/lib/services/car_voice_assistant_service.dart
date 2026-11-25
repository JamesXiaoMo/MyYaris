import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  bool get isRecording => _state == VoiceAssistantState.recording;
  bool get isBusy =>
      _state == VoiceAssistantState.thinking ||
      _state == VoiceAssistantState.speaking;

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

  Future<void> _startRecording(IStorageService storage) async {
    final baseUrl = _normalizeBaseUrl(storage.backendUrl);
    if (baseUrl.isEmpty || storage.carToken.trim().isEmpty) {
      _setError('请先在设置页配置后端地址和车机令牌');
      return;
    }

    _bannerDismissTimer?.cancel();
    _autoStopTimer?.cancel();

    // Lower music volume immediately so mic picks up driver's voice cleanly
    await BuiltInPlayerService().duckForVoiceInput();

    try {
      final res = await _voiceChannel.invokeMethod<String>('startRecording');
      if (res == 'PERMISSION_REQUESTED') {
        await BuiltInPlayerService().restoreMusicVolume();
        _setError('请先允许麦克风权限，然后再次点击「语音」');
        return;
      }
      _state = VoiceAssistantState.recording;
      _statusText = '正在聆听… 说完再点一次左侧「结束」';
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
      return;
    }

    if (wavPath == null || wavPath.trim().isEmpty) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('录音太短，请说完指令后再结束');
      return;
    }

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
      await _applyAssistantResponse(respJson);
    } catch (e) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('AI 助手连接失败：$e');
    }
  }

  /// Speaks a proactive Chinese navigation/safety announcement using backend TTS
  /// while temporarily ducking music volume to 15%.
  Future<void> speakAnnouncement(IStorageService storage, String text) async {
    final clean = text.trim();
    if (clean.isEmpty || isBusy || isRecording) return;
    final baseUrl = _normalizeBaseUrl(storage.backendUrl);
    if (baseUrl.isEmpty || storage.carToken.trim().isEmpty) return;

    _state = VoiceAssistantState.speaking;
    _statusText = '导航中文播报';
    _replyText = clean;
    _bannerVisible = true;
    notifyListeners();

    await BuiltInPlayerService().duckForVoiceInput();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      final uri = Uri.parse('$baseUrl/api/v1/assistant/tts');
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 10));
      req.headers.set('Authorization', 'Bearer ${storage.carToken}');
      req.headers.set('X-Device-Token', storage.carToken);
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode({'text': clean})));
      final resp = await req.close().timeout(const Duration(seconds: 12));
      final raw = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final decoded = jsonDecode(raw);
        final ttsUrl = decoded is Map ? (decoded['tts_url'] ?? '').toString().trim() : '';
        if (ttsUrl.isNotEmpty) {
          await BuiltInPlayerService().playVoiceReply(ttsUrl);
        } else {
          await BuiltInPlayerService().restoreMusicVolume();
        }
      } else {
        await BuiltInPlayerService().restoreMusicVolume();
      }
    } catch (e) {
      debugPrint('[VoiceAssistant] Proactive TTS note: $e');
      await BuiltInPlayerService().restoreMusicVolume();
    } finally {
      client.close(force: true);
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
    }
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
      await _applyAssistantResponse(respJson);
    } catch (e) {
      await BuiltInPlayerService().restoreMusicVolume();
      _setError('选点失败：$e');
    }
  }

  Future<void> _applyAssistantResponse(Map<String, dynamic> data) async {
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

    final ttsUrl = (data['tts_url'] ?? '').toString().trim();
    if (ttsUrl.isNotEmpty) {
      _state = VoiceAssistantState.speaking;
      _statusText = 'AI 语音播报中…';
      _bannerVisible = true;
      notifyListeners();
      await BuiltInPlayerService().playVoiceReply(ttsUrl);
    } else {
      await BuiltInPlayerService().restoreMusicVolume();
    }

    _state = VoiceAssistantState.idle;
    _statusText = _candidates.isNotEmpty ? '可直接点击下方地点，或再按「语音」说第几家' : '已完成';
    _bannerVisible = true;
    notifyListeners();

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
