import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/task_model.dart';

abstract class IStorageService {
  Future<void> init();
  String get backendUrl;
  Future<void> setBackendUrl(String url);
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
  List<TaskModel> get recentTasks;
  Future<void> addRecentTask(TaskModel task);
  Future<void> clearRecentTasks();
}

class SharedPreferencesStorageService implements IStorageService {
  static const String _keyBackendUrl = 'myyaris_backend_url';
  static const String _keyDeviceId = 'myyaris_device_id';
  static const String _keyCarToken = 'myyaris_car_token';
  static const String _keyPollingEnabled = 'myyaris_polling_enabled';
  static const String _keyProcessedTaskIds = 'myyaris_processed_task_ids';
  static const String _keyPendingAcks = 'myyaris_pending_acks';
  static const String _keyRecentTasks = 'myyaris_recent_tasks';

  static const String defaultBackendUrl =
      'https://myyaris.example.com';
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
