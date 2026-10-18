import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task_model.dart';
import 'backend_client.dart';

abstract class IStorageService {
  Future<void> init();
  String get backendUrl;
  Future<void> setBackendUrl(String url);
  Map<String, String> get fallbackDns;
  Future<void> setFallbackDns(Map<String, String> mapping);
  String get deviceId;
  Future<void> setDeviceId(String id);
  String get carToken;
  Future<void> setCarToken(String token);
  bool get isPollingEnabled;
  Future<void> setPollingEnabled(bool enabled);
  Set<String> get processedTaskIds;
  Future<void> addProcessedTaskId(String taskId);
  List<PendingAck> get pendingAcks;
  Future<void> savePendingAcks(List<PendingAck> acks);
  bool get isFullscreenEnabled;
  Future<void> setFullscreenEnabled(bool enabled);
  List<TaskModel> get recentTasks;
  Future<void> addRecentTask(TaskModel task);
  Future<void> clearRecentTasks();
}

class SharedPreferencesStorageService implements IStorageService {
  static const String _keyBackendUrl = 'myyaris_backend_url';
  static const String _keyFallbackDns = 'myyaris_fallback_dns';
  static const String _keyDeviceId = 'myyaris_device_id';
  static const String _keyCarToken = 'myyaris_car_token';
  static const String _keyPollingEnabled = 'myyaris_polling_enabled';
  static const String _keyFullscreenEnabled = 'myyaris_fullscreen_enabled';
  static const String _keyProcessedTaskIds = 'myyaris_processed_task_ids';
  static const String _keyPendingAcks = 'myyaris_pending_acks';
  static const String _keyRecentTasks = 'myyaris_recent_tasks';

  /// Default backend URL can be configured at compile time via:
  /// `--dart-define=MYYARIS_DEFAULT_BACKEND_URL=https://...`
  /// Defaults to an RFC 2606 reserved example domain so no private URLs are baked into the repository.
  static const String defaultBackendUrl = String.fromEnvironment(
    'MYYARIS_DEFAULT_BACKEND_URL',
    defaultValue: 'https://backend.example.com',
  );
  static const String defaultDeviceId = 'car_p3pro';

  final SharedPreferences _prefs;

  SharedPreferencesStorageService(this._prefs);

  static Future<SharedPreferencesStorageService> create() async {
    final prefs = await SharedPreferences.getInstance();
    return SharedPreferencesStorageService(prefs);
  }

  @override
  Future<void> init() async {
    // Already initialized via factory
  }

  @override
  String get backendUrl =>
      _prefs.getString(_keyBackendUrl)?.trim() ?? defaultBackendUrl;

  @override
  Future<void> setBackendUrl(String url) async {
    await _prefs.setString(_keyBackendUrl, url.trim());
  }

  @override
  Map<String, String> get fallbackDns {
    final raw = _prefs.getString(_keyFallbackDns);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString().trim(), v.toString().trim()));
        }
      } catch (_) {}
    }
    return BackendClient.defaultFallbackDns;
  }

  @override
  Future<void> setFallbackDns(Map<String, String> mapping) async {
    await _prefs.setString(_keyFallbackDns, json.encode(mapping));
  }

  @override
  String get deviceId =>
      _prefs.getString(_keyDeviceId)?.trim() ?? defaultDeviceId;

  @override
  Future<void> setDeviceId(String id) async {
    await _prefs.setString(_keyDeviceId, id.trim());
  }

  @override
  String get carToken => _prefs.getString(_keyCarToken)?.trim() ?? '';

  @override
  Future<void> setCarToken(String token) async {
    await _prefs.setString(_keyCarToken, token.trim());
  }

  @override
  bool get isPollingEnabled =>
      _prefs.getBool(_keyPollingEnabled) ?? false;

  @override
  Future<void> setPollingEnabled(bool enabled) async {
    await _prefs.setBool(_keyPollingEnabled, enabled);
  }

  @override
  bool get isFullscreenEnabled =>
      _prefs.getBool(_keyFullscreenEnabled) ?? true;

  @override
  Future<void> setFullscreenEnabled(bool enabled) async {
    await _prefs.setBool(_keyFullscreenEnabled, enabled);
  }

  @override
  Set<String> get processedTaskIds {
    final list = _prefs.getStringList(_keyProcessedTaskIds) ?? [];
    return list.toSet();
  }

  @override
  Future<void> addProcessedTaskId(String taskId) async {
    final current = processedTaskIds;
    current.add(taskId);
    // Keep max 500 recent IDs to avoid infinite growth
    final toSave = current.toList();
    if (toSave.length > 500) {
      toSave.removeRange(0, toSave.length - 500);
    }
    await _prefs.setStringList(_keyProcessedTaskIds, toSave);
  }

  @override
  List<PendingAck> get pendingAcks {
    final raw = _prefs.getString(_keyPendingAcks) ?? '';
    return PendingAck.decodeList(raw);
  }

  @override
  Future<void> savePendingAcks(List<PendingAck> acks) async {
    await _prefs.setString(_keyPendingAcks, PendingAck.encodeList(acks));
  }

  @override
  List<TaskModel> get recentTasks {
    final rawList = _prefs.getStringList(_keyRecentTasks) ?? [];
    final List<TaskModel> tasks = [];
    for (final raw in rawList) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        tasks.add(TaskModel.fromJson(decoded));
      } catch (_) {}
    }
    return tasks;
  }

  @override
  Future<void> addRecentTask(TaskModel task) async {
    final list = _prefs.getStringList(_keyRecentTasks) ?? [];
    list.insert(0, jsonEncode(task.toJson()));
    if (list.length > 50) {
      list.removeRange(50, list.length);
    }
    await _prefs.setStringList(_keyRecentTasks, list);
  }

  @override
  Future<void> clearRecentTasks() async {
    await _prefs.remove(_keyRecentTasks);
  }
}
