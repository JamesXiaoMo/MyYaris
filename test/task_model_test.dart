import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/task_model.dart';

void main() {
  group('TaskModel & Geo URI Tests', () {
    test('Correctly parses TaskModel from backend schema JSON', () {
      final json = {
        'task_id': 'task_123',
        'device_id': 'car_p3pro',
        'title': '广岛大学东广岛校区',
        'address': '日本广岛县东广岛市',
        'latitude': 34.399133,
        'longitude': 132.711467,
        'coord_system': 'wgs84',
        'status': 'queued',
        'created_at': '2026-10-06T10:00:00Z',
        'expires_at': '2026-10-06T11:00:00Z',
        'delivery_attempts': 1,
      };

      final model = TaskModel.fromJson(json);
      expect(model.taskId, 'task_123');
      expect(model.deviceId, 'car_p3pro');
      expect(model.title, '广岛大学东广岛校区');
      expect(model.latitude, 34.399133);
      expect(model.longitude, 132.711467);
      expect(model.coordSystem, 'wgs84');
      expect(model.status, 'queued');

      // Check strict geo URI contract: geo:0,0?q=lat,lon
      expect(model.toGeoUri(), 'geo:0,0?q=34.399133,132.711467');
    });

    test('Validates coordinates bounds properly', () {
      final valid = TaskModel(
        taskId: 't1',
        deviceId: 'c1',
        title: 'Valid Point',
        latitude: 35.0,
        longitude: 139.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(valid.hasValidCoordinates, isTrue);

      final invalidLat = TaskModel(
        taskId: 't2',
        deviceId: 'c1',
        title: 'Invalid Lat',
        latitude: 91.5,
        longitude: 139.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(invalidLat.hasValidCoordinates, isFalse);

      final invalidLon = TaskModel(
        taskId: 't3',
        deviceId: 'c1',
        title: 'Invalid Lon',
        latitude: 35.0,
        longitude: 185.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(invalidLon.hasValidCoordinates, isFalse);
    });

    test('Validates expiration status properly and fails closed', () {
      final notExpired = TaskModel(
        taskId: 't1',
        deviceId: 'c1',
        title: 'Fresh Task',
        latitude: 35.0,
        longitude: 139.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 55)),
      );
      expect(notExpired.isExpired, isFalse);

      final expired = TaskModel(
        taskId: 't2',
        deviceId: 'c1',
        title: 'Expired Task',
        latitude: 35.0,
        longitude: 139.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
        expiresAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
      );
      expect(expired.isExpired, isTrue);

      // Fail-closed test: null expiresAt is immediately treated as expired
      final nullExpires = TaskModel(
        taskId: 't3',
        deviceId: 'c1',
        title: 'No Expiry',
        latitude: 35.0,
        longitude: 139.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: null,
      );
      expect(nullExpires.isExpired, isTrue);

      // json with invalid/missing expires_at does NOT default to +1 hour
      final jsonMissingExpiry = {
        'task_id': 't4',
        'device_id': 'c1',
        'title': 'Missing Expiry',
        'latitude': 35.0,
        'longitude': 139.0,
        'coord_system': 'wgs84',
        'status': 'queued',
        'created_at': '2026-10-06T10:00:00Z',
        'expires_at': 'invalid_date',
      };
      final parsedMissing = TaskModel.fromJson(jsonMissingExpiry);
      expect(parsedMissing.expiresAt, isNull);
      expect(parsedMissing.isExpired, isTrue);
    });

    test('validateForExecution strictly verifies all required fields', () {
      final base = TaskModel(
        taskId: 'task_valid',
        deviceId: 'car_p3pro',
        title: 'Valid Destination',
        latitude: 34.399133,
        longitude: 132.711467,
        coordSystem: 'wgs84',
        status: 'queued',
        createdAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );

      // Valid case
      expect(base.validateForExecution(expectedDeviceId: 'car_p3pro'), isNull);

      // DeviceId mismatch
      expect(
        base.validateForExecution(expectedDeviceId: 'other_device'),
        contains('目标设备ID不匹配'),
      );

      // Empty taskId
      final emptyTaskId = TaskModel(
        taskId: '',
        deviceId: 'car_p3pro',
        title: 'Title',
        latitude: 34.0,
        longitude: 132.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(emptyTaskId.validateForExecution(expectedDeviceId: 'car_p3pro'), contains('任务ID为空'));

      // Status not queued or received (e.g. superseded, expired, failed)
      final supersededTask = TaskModel(
        taskId: 't_sup',
        deviceId: 'car_p3pro',
        title: 'Superseded',
        latitude: 34.0,
        longitude: 132.0,
        status: 'superseded',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(supersededTask.validateForExecution(expectedDeviceId: 'car_p3pro'), contains('任务状态非法'));

      // Unsupported coordSystem
      final gcj02Task = TaskModel(
        taskId: 't_gcj',
        deviceId: 'car_p3pro',
        title: 'GCJ02',
        latitude: 34.0,
        longitude: 132.0,
        coordSystem: 'gcj02',
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(gcj02Task.validateForExecution(expectedDeviceId: 'car_p3pro'), contains('不支持的坐标系'));

      // Invalid coordinates
      final outOfBoundsLat = TaskModel(
        taskId: 't_lat',
        deviceId: 'car_p3pro',
        title: 'Bad Lat',
        latitude: 100.0,
        longitude: 132.0,
        status: 'queued',
        createdAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      expect(outOfBoundsLat.validateForExecution(expectedDeviceId: 'car_p3pro'), contains('坐标非法'));
    });

    test('PendingAck encodes and decodes list reliably', () {
      final acks = [
        PendingAck(
          taskId: 't1',
          phase: TaskAckPhase.received,
          timestamp: DateTime.parse('2026-10-06T10:00:00Z'),
        ),
        PendingAck(
          taskId: 't2',
          phase: TaskAckPhase.launchRequested,
          timestamp: DateTime.parse('2026-10-06T10:05:00Z'),
        ),
        PendingAck(
          taskId: 't3',
          phase: TaskAckPhase.failed,
          timestamp: DateTime.parse('2026-10-06T10:10:00Z'),
          errorCode: 'LAUNCH_FAILED',
          errorDetail: 'Package not found',
          retryCount: 2,
        ),
      ];

      final encoded = PendingAck.encodeList(acks);
      final decoded = PendingAck.decodeList(encoded);

      expect(decoded.length, 3);
      expect(decoded[0].taskId, 't1');
      expect(decoded[0].phase, TaskAckPhase.received);
      expect(decoded[2].phase, TaskAckPhase.failed);
      expect(decoded[2].errorCode, 'LAUNCH_FAILED');
      expect(decoded[2].retryCount, 2);
    });
  });
}
