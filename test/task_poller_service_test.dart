import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/task_model.dart';
import 'package:my_yaris/services/backend_client.dart';
import 'package:my_yaris/services/task_poller_service.dart';
import 'mock_storage_service.dart';

class MockBackendClient extends BackendClient {
  TaskModel? nextTaskToReturn;
  TaskModel? freshTaskToReturn;
  AckResult ackResultToReturn = const AckResult.accepted();
  int getNextTaskCallCount = 0;
  int getTaskCallCount = 0;
  int acknowledgeTaskCallCount = 0;
  final List<TaskAckPhase> recordedPhases = [];
  Completer<void>? getNextTaskCompleter;
  bool repeatTask = false;
  bool _hasDeliveredTask = false;

  @override
  Future<TaskModel?> getNextTask({
    required String baseUrl,
    required String deviceId,
    required String token,
    int timeoutSeconds = 20,
  }) async {
    getNextTaskCallCount++;
    if (getNextTaskCompleter != null) {
      await getNextTaskCompleter!.future;
    }
    if (_hasDeliveredTask && !repeatTask) return null;
    if (nextTaskToReturn != null) _hasDeliveredTask = true;
    return nextTaskToReturn;
  }

  @override
  Future<TaskModel> getTask({
    required String baseUrl,
    required String taskId,
    required String token,
  }) async {
    getTaskCallCount++;
    return freshTaskToReturn ?? nextTaskToReturn!;
  }

  @override
  Future<AckResult> acknowledgeTask({
    required String baseUrl,
    required String taskId,
    required String token,
    required TaskAckPhase phase,
    DateTime? deviceTimestamp,
    String? errorCode,
    String? errorDetail,
  }) async {
    acknowledgeTaskCallCount++;
    recordedPhases.add(phase);
    return ackResultToReturn;
  }

  @override
  void close() {}
}

void main() {
  group('TaskPollerService Logic & Concurrency Tests', () {
    late MockStorageService storage;
    late MockBackendClient mockClient;
    late TaskPollerService poller;

    setUp(() {
      storage = MockStorageService();
      mockClient = MockBackendClient();
      poller = TaskPollerService(storage: storage, client: mockClient);
    });

    tearDown(() {
      poller.dispose();
    });

    test('Initial poller state is idle and can start/stop', () {
      expect(poller.status, PollerStatus.idle);
      expect(poller.isRunning, isFalse);

      poller.start();
      expect(poller.isRunning, isTrue);
      expect(storage.isPollingEnabled, isTrue);

      poller.stop();
      expect(poller.isRunning, isFalse);
      expect(storage.isPollingEnabled, isFalse);
      expect(poller.status, PollerStatus.idle);
    });

    test('Stops with pausedAuthError if token is empty', () async {
      await storage.setCarToken('');
      poller.start();
      await Future.delayed(const Duration(milliseconds: 50));

      expect(poller.isRunning, isFalse);
      expect(poller.status, PollerStatus.pausedAuthError);
      expect(poller.statusMessage, contains('未配置车机令牌'));
    });

    test('start-stop-start does not spawn duplicate concurrent loops', () async {
      // Toggle poller quickly multiple times
      poller.start();
      poller.stop();
      poller.start();
      poller.stop();
      poller.start();

      expect(poller.isRunning, isTrue);
      // Wait for loop to register
      await Future.delayed(const Duration(milliseconds: 50));

      poller.stop();
      expect(poller.isRunning, isFalse);
      expect(poller.status, PollerStatus.idle);
    });

    test('Stopping poller prevents received task from being executed', () async {
      final taskCompleter = Completer<void>();
      mockClient.getNextTaskCompleter = taskCompleter;
      mockClient.nextTaskToReturn = TaskModel(
        taskId: 'task_should_not_run',
        deviceId: 'car_p3pro',
        title: 'Cancel Test',
        latitude: 34.399,
        longitude: 132.711,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      poller.start();
      await Future.delayed(const Duration(milliseconds: 20));

      // Stop while waiting in getNextTask
      poller.stop();

      // Release the task
      taskCompleter.complete();
      await Future.delayed(const Duration(milliseconds: 50));

      // Verify that no ack was sent, getTask was never called, and task was not executed
      expect(mockClient.recordedPhases, isEmpty);
      expect(mockClient.getTaskCallCount, 0);
      expect(storage.processedTaskIds.contains('task_should_not_run'), isFalse);
    });

    test('Explicit rejection of received ack aborts execution and skips Intent', () async {
      mockClient.ackResultToReturn = const AckResult.rejected(
        message: 'Task already cancelled or superseded on server',
        statusCode: 200,
      );
      mockClient.nextTaskToReturn = TaskModel(
        taskId: 'task_rejected',
        deviceId: 'car_p3pro',
        title: 'Rejection Test',
        latitude: 34.399,
        longitude: 132.711,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      poller.start();
      await Future.delayed(const Duration(milliseconds: 60));
      poller.stop();

      // Received ack was attempted
      expect(mockClient.recordedPhases, contains(TaskAckPhase.received));
      // But launch_requested was never sent because received was rejected!
      expect(mockClient.recordedPhases.contains(TaskAckPhase.launchRequested), isFalse);
      // getTask was never called
      expect(mockClient.getTaskCallCount, 0);
      // Task was recorded in processedTaskIds to avoid retry loops
      expect(storage.processedTaskIds.contains('task_rejected'), isTrue);
    });

    test('GET /tasks/{id} re-check detects superseded status and aborts launch', () async {
      final initialTask = TaskModel(
        taskId: 'task_superseded',
        deviceId: 'car_p3pro',
        title: 'Superseded Destination',
        latitude: 34.399,
        longitude: 132.711,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      final serverUpdatedTask = TaskModel(
        taskId: 'task_superseded',
        deviceId: 'car_p3pro',
        title: 'Superseded Destination',
        latitude: 34.399,
        longitude: 132.711,
        status: 'superseded', // Server says superseded!
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      mockClient.nextTaskToReturn = initialTask;
      mockClient.freshTaskToReturn = serverUpdatedTask;
      mockClient.ackResultToReturn = const AckResult.accepted();

      poller.start();
      await Future.delayed(const Duration(milliseconds: 60));
      poller.stop();

      // received was sent
      expect(mockClient.recordedPhases, contains(TaskAckPhase.received));
      // GET /tasks/{id} was called
      expect(mockClient.getTaskCallCount, greaterThanOrEqualTo(1));
      // launchRequested was NOT sent!
      expect(mockClient.recordedPhases.contains(TaskAckPhase.launchRequested), isFalse);
    });

    test('Pre-execution validation failure reports failed ack immediately without received', () async {
      // Task with invalid coordinate lat = 999.0
      mockClient.nextTaskToReturn = TaskModel(
        taskId: 'task_bad_coords',
        deviceId: 'car_p3pro',
        title: 'Bad Coordinates',
        latitude: 999.0,
        longitude: 132.711,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      poller.start();
      await Future.delayed(const Duration(milliseconds: 60));
      poller.stop();

      expect(mockClient.recordedPhases, contains(TaskAckPhase.failed));
      expect(mockClient.recordedPhases.contains(TaskAckPhase.received), isFalse);
      expect(mockClient.getTaskCallCount, 0);
    });

    test('PendingAcks list queueing and retry management', () async {
      final ack = PendingAck(
        taskId: 'task_ack_1',
        phase: TaskAckPhase.received,
        timestamp: DateTime.now().toUtc(),
      );

      await storage.savePendingAcks([ack]);
      expect(storage.pendingAcks.length, 1);
      expect(storage.pendingAcks[0].taskId, 'task_ack_1');

      final updated = ack.copyWithIncrementRetry();
      expect(updated.retryCount, 1);
      await storage.savePendingAcks([updated]);
      expect(storage.pendingAcks[0].retryCount, 1);
    });

    test('Immediate duplicate delivery yields so timers can stop polling', () async {
      mockClient.repeatTask = true;
      mockClient.nextTaskToReturn = TaskModel(
        taskId: 'already_processed',
        deviceId: 'car_p3pro',
        title: 'Duplicate',
        latitude: 34.399,
        longitude: 132.711,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      await storage.addProcessedTaskId('already_processed');
      poller.start();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      poller.stop();
      expect(mockClient.getNextTaskCallCount, inInclusiveRange(1, 3));
      expect(mockClient.recordedPhases, isEmpty);
      expect(mockClient.getTaskCallCount, 0);
    }, timeout: const Timeout(Duration(seconds: 5)));
  });
}
