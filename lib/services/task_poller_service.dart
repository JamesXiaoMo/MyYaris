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

  int _loopGeneration = 0;
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
    _loopGeneration++;
    final currentGen = _loopGeneration;
    storage.setPollingEnabled(true);
    _consecutiveFailures = 0;
    _log('启动车机长轮询接收引擎 (Loop Gen: $currentGen)');
    _runLoop(currentGen);
  }

  void stop() {
    if (!_isRunning) return;
    _isRunning = false;
    _loopGeneration++; // Invalidate any running loops or in-flight tasks
    storage.setPollingEnabled(false);
    _status = PollerStatus.idle;
    _statusMessage = '已停止接收';
    final sleep = _activeSleepCompleter;
    if (sleep != null && !sleep.isCompleted) sleep.complete();
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
    if (identical(_activeSleepCompleter, completer)) {
      _activeSleepCompleter = null;
    }
  }

  Future<void> _runLoop(int gen) async {
    while (_isRunning && _loopGeneration == gen) {
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

      if (!_isRunning || _loopGeneration != gen) break;

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

        if (!_isRunning || _loopGeneration != gen) {
          _log('轮询已停止，丢弃本次长轮询响应');
          break;
        }

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

        await _processIncomingTask(task, backendUrl, carToken, gen);
        // A server may immediately redeliver an unacknowledged task. Yield to
        // timers and bound request frequency, including duplicate/rejected tasks.
        if (_isRunning && _loopGeneration == gen) {
          await _sleepCancelable(const Duration(milliseconds: 100));
        }
      } on AuthException catch (e) {
        _status = PollerStatus.pausedAuthError;
        _statusMessage = '鉴权失败 (HTTP ${e.statusCode})，请检查令牌';
        _log('错误: 后端拒绝连接鉴权 (${e.message})');
        notifyListeners();
        _isRunning = false;
        await storage.setPollingEnabled(false);
        break;
      } catch (e) {
        if (!_isRunning || _loopGeneration != gen) break;
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
    int gen,
  ) async {
    // Abort if poller stopped or restarted
    if (!_isRunning || _loopGeneration != gen) {
      _log('长轮询已停止，中止处理任务 [${task.taskId}]');
      return;
    }

    // 1. Check idempotency: Was this task already processed?
    if (storage.processedTaskIds.contains(task.taskId)) {
      _log('任务 [${task.taskId}] 已在本地持久化列表中，跳过重复执行');
      return;
    }

    // 2. Strict Pre-execution Check:
    // taskId, deviceId, status (queued/received), coordSystem (wgs84), coordinates, createdAt, expiresAt (fail-closed)
    final validationError = task.validateForExecution(expectedDeviceId: storage.deviceId);
    if (validationError != null) {
      _log('任务 [${task.taskId}] 本地校验未通过 ($validationError)，上报 failed 回执');
      await _sendAck(
        backendUrl: backendUrl,
        carToken: carToken,
        taskId: task.taskId,
        phase: TaskAckPhase.failed,
        errorCode: 'VALIDATION_FAILED',
        errorDetail: validationError,
      );
      await storage.addRecentTask(task.copyWith(
        status: TaskAckPhase.failed.value,
        errorMessage: validationError,
      ));
      await storage.addProcessedTaskId(task.taskId);
      return;
    }

    if (!_isRunning || _loopGeneration != gen) {
      _log('长轮询已停止，中止处理任务 [${task.taskId}]');
      return;
    }

    // 3. Report 'received' phase ack
    _log('向后端上报 [received] 回执...');
    final receivedAckResult = await _sendAck(
      backendUrl: backendUrl,
      carToken: carToken,
      taskId: task.taskId,
      phase: TaskAckPhase.received,
    );

    // If explicit rejection by backend (accepted == false or 4xx):
    if (receivedAckResult.isExplicitlyRejected) {
      final rejectReason = receivedAckResult.message ?? 'accepted=false';
      _log('任务 [${task.taskId}] received 回执被后端明确拒绝 ($rejectReason)，绝不拉起 Intent');
      await storage.addRecentTask(task.copyWith(
        status: TaskAckPhase.failed.value,
        errorMessage: '后端明确拒绝: $rejectReason',
      ));
      await storage.addProcessedTaskId(task.taskId);
      return;
    }

    // If network uncertainty on received ack:
    if (receivedAckResult.isNetworkError) {
      _log('任务 [${task.taskId}] received 回执网络发送不确定 (${receivedAckResult.error})，不盲目拉起 Intent，持久化等待重试');
      return;
    }

    if (!_isRunning || _loopGeneration != gen) {
      _log('长轮询已停止，中止处理任务 [${task.taskId}]');
      return;
    }

    // 4. Re-check latest task status via GET /tasks/{id}
    _log('正在向后端 GET /tasks/${task.taskId} 复核最新任务状态与有效期...');
    TaskModel freshTask;
    try {
      freshTask = await _client.getTask(
        baseUrl: backendUrl,
        taskId: task.taskId,
        token: carToken,
      );
    } catch (e) {
      _log('复核任务 [${task.taskId}] 最新状态网络失败 ($e)，不盲目拉起，持久化等待重试');
      return;
    }

    // Validate fresh task ID matches the initial task
    if (freshTask.taskId != task.taskId) {
      _log('任务 [${task.taskId}] 复核ID不一致: 服务端返回 [${freshTask.taskId}]，取消拉起');
      await storage.addRecentTask(task.copyWith(
        status: TaskAckPhase.failed.value,
        errorMessage: '服务端复核ID不一致: ${freshTask.taskId}',
      ));
      await storage.addProcessedTaskId(task.taskId);
      return;
    }

    // Comprehensive validation on freshTask (status, deviceId, coordSystem, coordinates, expiry)
    final freshValidationError = freshTask.validateForExecution(expectedDeviceId: storage.deviceId);
    if (freshValidationError != null) {
      _log('任务 [${task.taskId}] 服务端最新数据复核未通过 ($freshValidationError)，上报 failed 并取消拉起');
      await _sendAck(
        backendUrl: backendUrl,
        carToken: carToken,
        taskId: task.taskId,
        phase: TaskAckPhase.failed,
        errorCode: 'FRESH_VALIDATION_FAILED',
        errorDetail: freshValidationError,
      );
      await storage.addRecentTask(freshTask.copyWith(
        status: TaskAckPhase.failed.value,
        errorMessage: freshValidationError,
      ));
      await storage.addProcessedTaskId(task.taskId);
      return;
    }

    if (!_isRunning || _loopGeneration != gen) {
      _log('长轮询已停止，中止打开 CAR NAVITIME');
      return;
    }

    // 5. Generate actual geo URI: geo:0,0?q=lat,lon
    final geoUri = freshTask.toGeoUri();
    _status = PollerStatus.launchingNavigation;
    _statusMessage = '正在向系统发起打开 CAR NAVITIME 请求: $geoUri';
    _log('调用系统 MethodChannel 发起打开 CAR NAVITIME 请求: $geoUri (指定包名: com.navitime.local.carnavitime)');
    notifyListeners();

    // 6. Invoke MethodChannel
    try {
      final res = await _navChannel.invokeMethod<Map<dynamic, dynamic>>(
        'launchCarNavitime',
        {'geoUri': geoUri},
      );

      final success = res?['success'] == true;
      if (success) {
        // Requirement 4: Success log only states launch request initiated, does not claim navigation confirmed
        _log('已向系统发起打开 CAR NAVITIME 请求，上报 [launch_requested] 回执');
        await storage.addRecentTask(freshTask.copyWith(
          status: TaskAckPhase.launchRequested.value,
        ));
        await storage.addProcessedTaskId(freshTask.taskId);
        await _sendAck(
          backendUrl: backendUrl,
          carToken: carToken,
          taskId: freshTask.taskId,
          phase: TaskAckPhase.launchRequested,
        );
        _statusMessage = '已发起打开请求: ${freshTask.title}';
      } else {
        throw Exception('Native returned non-success response: $res');
      }
    } catch (e) {
      _log('发起打开 CAR NAVITIME 请求失败: $e，上报 [failed] 回执');
      await storage.addRecentTask(freshTask.copyWith(
        status: TaskAckPhase.failed.value,
        errorMessage: '发起打开请求失败: $e',
      ));
      await storage.addProcessedTaskId(freshTask.taskId);
      await _sendAck(
        backendUrl: backendUrl,
        carToken: carToken,
        taskId: freshTask.taskId,
        phase: TaskAckPhase.failed,
        errorCode: 'INTENT_LAUNCH_FAILED',
        errorDetail: e.toString(),
      );
      _statusMessage = '发起打开请求失败: $e';
    }

    notifyListeners();
  }

  Future<AckResult> _sendAck({
    required String backendUrl,
    required String carToken,
    required String taskId,
    required TaskAckPhase phase,
    String? errorCode,
    String? errorDetail,
  }) async {
    final timestamp = DateTime.now().toUtc();
    try {
      final result = await _client.acknowledgeTask(
        baseUrl: backendUrl,
        taskId: taskId,
        token: carToken,
        phase: phase,
        deviceTimestamp: timestamp,
        errorCode: errorCode,
        errorDetail: errorDetail,
      );

      if (result.isAccepted) {
        _log('回执上报成功: [${phase.value}] task=$taskId');
        return result;
      }

      if (result.isExplicitlyRejected) {
        _log('回执被服务端明确拒绝: [${phase.value}] task=$taskId msg=${result.message}');
        return result;
      }

      _log('回执发送遇网络异常 (${result.error})，持久化至待发队列重试: [${phase.value}]');
    } catch (e) {
      _log('回执发送异常 ($e)，持久化至待发队列重试: [${phase.value}]');
    }

    final pendingList = storage.pendingAcks;
    pendingList.add(PendingAck(
      taskId: taskId,
      phase: phase,
      timestamp: timestamp,
      errorCode: errorCode,
      errorDetail: errorDetail,
    ));
    await storage.savePendingAcks(pendingList);
    return AckResult.networkError('Ack persisted for retry');
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
        final result = await _client.acknowledgeTask(
          baseUrl: backendUrl,
          taskId: item.taskId,
          token: carToken,
          phase: item.phase,
          deviceTimestamp: item.timestamp,
          errorCode: item.errorCode,
          errorDetail: item.errorDetail,
        );
        if (result.isAccepted) {
          _log('重发补报回执成功: [${item.phase.value}] task=${item.taskId}');
        } else if (result.isExplicitlyRejected) {
          _log('重发补报回执被服务端拒绝 (${result.message})，舍弃: [${item.phase.value}]');
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
