import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/task_model.dart';
import 'backend_client.dart';
import 'storage_service.dart';

enum PollerStatus {
  idle,
  polling,
  receivedTask,
  launchingNavigation,
  reconnecting,
  pausedAuthError,
  error,
}

class TaskPollerService extends ChangeNotifier {
  static const MethodChannel _navChannel =
      MethodChannel('com.myyaris.my_yaris/navigation');

  final IStorageService storage;
  final BackendClient _client;

  PollerStatus _status = PollerStatus.idle;
  String _statusMessage = '待命中 (接收未启用)';
  int _consecutiveFailures = 0;
  bool _isRunning = false;
  Completer<void>? _activeSleepCompleter;
  TaskModel? _currentTask;
  final List<String> _activityLogs = [];

  TaskPollerService({
    required this.storage,
    BackendClient? client,
  })  : _client = client ?? BackendClient();

  PollerStatus get status => _status;
  String get statusMessage => _statusMessage;
  bool get isRunning => _isRunning;
  TaskModel? get currentTask => _currentTask;
  List<String> get activityLogs => List.unmodifiable(_activityLogs);
  List<TaskModel> get recentTasks => storage.recentTasks;

  void _log(String message) {
    final now = DateTime.now().toLocal();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
    _activityLogs.insert(0, '[$timeStr] $message');
    if (_activityLogs.length > 100) {
      _activityLogs.removeRange(100, _activityLogs.length);
    }
    notifyListeners();
  }

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    storage.setPollingEnabled(true);
    _consecutiveFailures = 0;
    _log('启动车机长轮询接收引擎');
    _runLoop();
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    storage.setPollingEnabled(false);
    _status = PollerStatus.idle;
    _statusMessage = '已停止接收';
    _activeSleepCompleter?.complete();
    _log('已手动停止长轮询');
    notifyListeners();
  }

  Future<void> _sleepCancelable(Duration duration) async {
    final completer = Completer<void>();
    _activeSleepCompleter = completer;
    final timer = Timer(duration, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;
    timer.cancel();
    _activeSleepCompleter = null;
  }

  Future<void> _runLoop() async {
    while (_isRunning) {
      final backendUrl = storage.backendUrl;
      final deviceId = storage.deviceId;
      final carToken = storage.carToken;

      if (carToken.isEmpty) {
        _status = PollerStatus.pausedAuthError;
        _statusMessage = '未配置车机令牌 (CAR_TOKEN)，已暂停轮询';
        _log('警告: 车机令牌为空，请在设置中输入后重新开启');
        notifyListeners();
        _isRunning = false;
        await storage.setPollingEnabled(false);
        break;
      }

      // Flush any pending un-acknowledged receipts from previous attempts
      await _flushPendingAcks(backendUrl, carToken);

      _status = PollerStatus.polling;
      _statusMessage = '正在长轮询后端任务 (/devices/$deviceId/tasks/next)...';
      notifyListeners();

      try {
        final task = await _client.getNextTask(
          baseUrl: backendUrl,
          deviceId: deviceId,
          token: carToken,
          timeoutSeconds: 20,
        );

        if (!_isRunning) break;

        if (task == null) {
          // 204 No Content: timeout reached, server has no new task
          _consecutiveFailures = 0;
          _statusMessage = '长轮询已就绪 (暂无待接收任务，继续保持连接)';
          notifyListeners();
          // Small pause to yield execution
          await Future.delayed(const Duration(milliseconds: 300));
          continue;
        }

        // Successfully received a task!
        _consecutiveFailures = 0;
        _currentTask = task;
        _status = PollerStatus.receivedTask;
        _statusMessage = '收到新导航任务: ${task.title}';
        _log('收到任务 [${task.taskId}] 目标: ${task.title} (${task.latitude}, ${task.longitude})');
        notifyListeners();

        await _processIncomingTask(task, backendUrl, carToken);
      } on AuthException catch (e) {
        _status = PollerStatus.pausedAuthError;
        _statusMessage = '鉴权失败 (HTTP ${e.statusCode})，请检查令牌';
        _log('错误: 后端拒绝连接鉴权 (${e.message})');
        notifyListeners();
        _isRunning = false;
        await storage.setPollingEnabled(false);
        break;
      } catch (e) {
        if (!_isRunning) break;
        _consecutiveFailures++;
        final backoffSeconds = _calculateBackoff(_consecutiveFailures);
        _status = PollerStatus.reconnecting;
        _statusMessage = '连接异常 ($e)，将在 ${backoffSeconds}s 后重试';
        _log('轮询异常: $e (连续失败 $_consecutiveFailures 次，退避 ${backoffSeconds}s)');
        notifyListeners();

        await _sleepCancelable(Duration(seconds: backoffSeconds));
      }
    }
  }

  int _calculateBackoff(int failures) {
    if (failures <= 1) return 2;
    if (failures == 2) return 4;
    if (failures == 3) return 8;
    if (failures == 4) return 16;
    return 30; // max 30s
  }

  Future<void> _processIncomingTask(
    TaskModel task,
    String backendUrl,
    String carToken,
  ) async {
    // 1. Check idempotency: Was this task already processed?
    if (storage.processedTaskIds.contains(task.taskId)) {
      _log('任务 [${task.taskId}] 已在本地持久化列表中，跳过重复执行');
      return;
    }

    // 2. Validate expiration
    if (task.isExpired) {
      _log('任务 [${task.taskId}] 已过期 (过期时间: ${task.expiresAt})，上报 failed 回执');
      await _sendAck(
        backendUrl: backendUrl,
        carToken: carToken,
        taskId: task.taskId,
        phase: TaskAckPhase.failed,
        errorCode: 'TASK_EXPIRED',
        errorDetail: 'Task expired on device before launch',
      );
      await storage.addProcessedTaskId(task.taskId);
      return;
    }

    // 3. Validate coordinates
    if (!task.hasValidCoordinates) {
      _log('任务 [${task.taskId}] 经纬度无效 (${task.latitude}, ${task.longitude})，上报 failed 回执');
      await _sendAck(
        backendUrl: backendUrl,
        carToken: carToken,
        taskId: task.taskId,
        phase: TaskAckPhase.failed,
        errorCode: 'INVALID_COORDINATES',
        errorDetail: 'Coordinates out of bounds: lat=${task.latitude}, lon=${task.longitude}',
      );
      await storage.addProcessedTaskId(task.taskId);
      return;
    }

    // 4. Report 'received' phase ack
    _log('向后端上报 [received] 回执...');
    await _sendAck(
      backendUrl: backendUrl,
      carToken: carToken,
      taskId: task.taskId,
      phase: TaskAckPhase.received,
    );

    // 5. Generate actual geo URI: geo:0,0?q=lat,lon
    final geoUri = task.toGeoUri();
    _status = PollerStatus.launchingNavigation;
    _statusMessage = '正在拉起 CAR NAVITIME: $geoUri';
    _log('调用系统 MethodChannel 拉起 CAR NAVITIME: $geoUri (指定包名: com.navitime.local.carnavitime)');
    notifyListeners();

    // 6. Invoke MethodChannel
    try {
      final res = await _navChannel.invokeMethod<Map<dynamic, dynamic>>(
        'launchCarNavitime',
        {'geoUri': geoUri},
      );

      final success = res?['success'] == true;
      if (success) {
        _log('CAR NAVITIME 成功拉起！上报 [launch_requested] 回执');
        await storage.addProcessedTaskId(task.taskId);
        await storage.addRecentTask(task);
        await _sendAck(
          backendUrl: backendUrl,
          carToken: carToken,
          taskId: task.taskId,
          phase: TaskAckPhase.launchRequested,
        );
        _statusMessage = '导航拉起成功: ${task.title}';
      } else {
        throw Exception('Native returned non-success response: $res');
      }
    } catch (e) {
      _log('拉起 CAR NAVITIME 失败: $e，上报 [failed] 回执');
      await storage.addProcessedTaskId(task.taskId);
      await _sendAck(
        backendUrl: backendUrl,
        carToken: carToken,
        taskId: task.taskId,
        phase: TaskAckPhase.failed,
        errorCode: 'INTENT_LAUNCH_FAILED',
        errorDetail: e.toString(),
      );
      _statusMessage = '拉起失败: $e';
    }

    notifyListeners();
  }

  Future<void> _sendAck({
    required String backendUrl,
    required String carToken,
    required String taskId,
    required TaskAckPhase phase,
    String? errorCode,
    String? errorDetail,
  }) async {
    final timestamp = DateTime.now().toUtc();
    try {
      final ok = await _client.acknowledgeTask(
        baseUrl: backendUrl,
        taskId: taskId,
        token: carToken,
        phase: phase,
        deviceTimestamp: timestamp,
        errorCode: errorCode,
        errorDetail: errorDetail,
      );
      if (ok) {
        _log('回执上报成功: [${phase.value}] task=$taskId');
        return;
      }
    } catch (e) {
      _log('回执即时发送失败 ($e)，持久化至本地待发队列重试: [${phase.value}]');
    }

    // If ack failed or threw, persist as PendingAck for retry
    final pendingList = storage.pendingAcks;
    pendingList.add(PendingAck(
      taskId: taskId,
      phase: phase,
      timestamp: timestamp,
      errorCode: errorCode,
      errorDetail: errorDetail,
    ));
    await storage.savePendingAcks(pendingList);
  }

  Future<void> _flushPendingAcks(String backendUrl, String carToken) async {
    final pending = storage.pendingAcks;
    if (pending.isEmpty) return;

    final List<PendingAck> remaining = [];
    for (final item in pending) {
      if (item.retryCount >= 5) {
        _log('待发回执 [${item.phase.value}] task=${item.taskId} 已达最大重试次数，舍弃');
        continue;
      }
      try {
        final ok = await _client.acknowledgeTask(
          baseUrl: backendUrl,
          taskId: item.taskId,
          token: carToken,
          phase: item.phase,
          deviceTimestamp: item.timestamp,
          errorCode: item.errorCode,
          errorDetail: item.errorDetail,
        );
        if (ok) {
          _log('重发补报回执成功: [${item.phase.value}] task=${item.taskId}');
        } else {
          remaining.add(item.copyWithIncrementRetry());
        }
      } catch (_) {
        remaining.add(item.copyWithIncrementRetry());
      }
    }
    await storage.savePendingAcks(remaining);
  }

  @override
  void dispose() {
    stop();
    _client.close();
    super.dispose();
  }
}
