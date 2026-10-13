import 'package:my_yaris/models/task_model.dart';
import 'package:my_yaris/services/storage_service.dart';

class MockStorageService implements IStorageService {
  String _url = 'https://mock.backend.ts.net';
  String _deviceId = 'car_p3pro';
  String _carToken = 'test-token';
  bool _pollingEnabled = false;
  final Set<String> _processedIds = {};
  List<PendingAck> _pending = [];
  final List<TaskModel> _recent = [];

  @override
  Future<void> init() async {}

  @override
  String get backendUrl => _url;
  @override
  Future<void> setBackendUrl(String url) async => _url = url;

  @override
  String get deviceId => _deviceId;
  @override
  Future<void> setDeviceId(String id) async => _deviceId = id;

  @override
  String get carToken => _carToken;
  @override
  Future<void> setCarToken(String token) async => _carToken = token;

  @override
  bool get isPollingEnabled => _pollingEnabled;
  @override
  Future<void> setPollingEnabled(bool enabled) async => _pollingEnabled = enabled;

  bool _fullscreenEnabled = true;
  @override
  bool get isFullscreenEnabled => _fullscreenEnabled;
  @override
  Future<void> setFullscreenEnabled(bool enabled) async => _fullscreenEnabled = enabled;

  @override
  Set<String> get processedTaskIds => Set.from(_processedIds);
  @override
  Future<void> addProcessedTaskId(String taskId) async => _processedIds.add(taskId);

  @override
  List<PendingAck> get pendingAcks => List.from(_pending);
  @override
  Future<void> savePendingAcks(List<PendingAck> acks) async => _pending = List.from(acks);

  @override
  List<TaskModel> get recentTasks => List.from(_recent);
  @override
  Future<void> addRecentTask(TaskModel task) async => _recent.insert(0, task);
  @override
  Future<void> clearRecentTasks() async => _recent.clear();
}
