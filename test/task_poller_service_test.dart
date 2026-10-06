import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/task_model.dart';
import 'package:my_yaris/services/task_poller_service.dart';
import 'mock_storage_service.dart';

void main() {
  group('TaskPollerService Logic Tests', () {
    late MockStorageService storage;
    late TaskPollerService poller;

    setUp(() {
      storage = MockStorageService();
      poller = TaskPollerService(storage: storage);
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
      // Yield to let loop evaluate
      await Future.delayed(const Duration(milliseconds: 50));

      expect(poller.isRunning, isFalse);
      expect(poller.status, PollerStatus.pausedAuthError);
      expect(poller.statusMessage, contains('未配置车机令牌'));
    });

    test('Task deduplication and processed IDs persistence', () async {
      await storage.addProcessedTaskId('task_already_done');
      expect(storage.processedTaskIds.contains('task_already_done'), isTrue);

      final task = TaskModel(
        taskId: 'task_already_done',
        deviceId: 'car_p3pro',
        title: 'Old Task',
        latitude: 34.399,
        longitude: 132.711,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      // Verify that model coordinates and geoURI match expectations
      expect(task.hasValidCoordinates, isTrue);
      expect(task.toGeoUri(), 'geo:0,0?q=34.399,132.711');
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
  });
}
