import 'dart:convert';

enum TaskAckPhase {
  received('received'),
  launchRequested('launch_requested'),
  failed('failed');

  final String value;
  const TaskAckPhase(this.value);

  static TaskAckPhase fromString(String val) {
    for (final phase in TaskAckPhase.values) {
      if (phase.value == val) return phase;
    }
    return TaskAckPhase.failed;
  }
}

class TaskModel {
  final String taskId;
  final String deviceId;
  final String title;
  final String? address;
  final double latitude;
  final double longitude;
  final String coordSystem;
  final String status;
  final DateTime? createdAt;
  final DateTime? expiresAt;
  final int deliveryAttempts;
  final String? errorMessage;

  const TaskModel({
    required this.taskId,
    required this.deviceId,
    required this.title,
    this.address,
    required this.latitude,
    required this.longitude,
    this.coordSystem = 'wgs84',
    required this.status,
    required this.createdAt,
    required this.expiresAt,
    this.deliveryAttempts = 0,
    this.errorMessage,
  });

  /// Fail-closed: If expiresAt is null or unparseable, it is considered expired.
  bool get isExpired {
    if (expiresAt == null) return true;
    return DateTime.now().toUtc().isAfter(expiresAt!.toUtc());
  }

  /// Strict coordinate validation
  bool get hasValidCoordinates {
    return latitude >= -90.0 &&
        latitude <= 90.0 &&
        longitude >= -180.0 &&
        longitude <= 180.0;
  }

  /// Strict pre-execution check:
  /// - task.taskId non-empty
  /// - task.deviceId matches current device
  /// - task.status is strictly queued or received
  /// - task.coordSystem is strictly wgs84
  /// - valid coordinates
  /// - valid createdAt format
  /// - valid expiresAt format and not expired (fail-closed)
  String? validateForExecution({required String expectedDeviceId}) {
    if (taskId.trim().isEmpty) {
      return '任务ID为空 (Empty taskId)';
    }
    if (deviceId.trim() != expectedDeviceId.trim()) {
      return '目标设备ID不匹配: 任务设备 $deviceId != 当前配置 $expectedDeviceId';
    }
    final normalizedStatus = status.toLowerCase();
    if (normalizedStatus != 'queued' && normalizedStatus != 'received') {
      return '任务状态非法: $status (仅允许 queued 或 received)';
    }
    if (coordSystem.trim().toLowerCase() != 'wgs84') {
      return '不支持的坐标系: $coordSystem (仅支持 wgs84)';
    }
    if (!hasValidCoordinates) {
      return '坐标非法: lat=$latitude, lon=$longitude';
    }
    if (createdAt == null) {
      return '创建时间格式无效 (Invalid created_at)';
    }
    if (expiresAt == null) {
      return '过期时间格式无效或缺失 (Fail closed: Invalid expires_at)';
    }
    if (DateTime.now().toUtc().isAfter(expiresAt!.toUtc())) {
      return '任务已过期 (Task expired at ${expiresAt!.toIso8601String()})';
    }
    return null; // Valid!
  }

  /// Generates the standard geo URI as required: geo:0,0?q=lat,lon
  String toGeoUri() {
    return 'geo:0,0?q=$latitude,$longitude';
  }

  /// Helper to safely parse UTC datetimes. Server naive ISO strings without timezone (e.g. 2026-10-06T12:43:09.926576)
  /// are treated as UTC rather than local device time.
  static DateTime? parseUtcDateTime(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    var str = raw.trim();
    if (!str.endsWith('Z') && !str.contains('+') && !RegExp(r'-\d{2}:\d{2}$').hasMatch(str)) {
      str = '${str}Z';
    }
    return DateTime.tryParse(str)?.toUtc();
  }

  factory TaskModel.fromJson(Map<String, dynamic> json) {
    final parsedCreatedAt = parseUtcDateTime(json['created_at'] as String?);
    final parsedExpiresAt = parseUtcDateTime(json['expires_at'] as String?);

    return TaskModel(
      taskId: json['task_id'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      address: json['address'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      coordSystem: json['coord_system'] as String? ?? 'wgs84',
      status: json['status'] as String? ?? 'queued',
      createdAt: parsedCreatedAt,
      expiresAt: parsedExpiresAt,
      deliveryAttempts: json['delivery_attempts'] as int? ?? 0,
      errorMessage: json['error_message'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'task_id': taskId,
      'device_id': deviceId,
      'title': title,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'coord_system': coordSystem,
      'status': status,
      'created_at': createdAt?.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'delivery_attempts': deliveryAttempts,
      'error_message': errorMessage,
    };
  }
}

class PendingAck {
  final String taskId;
  final TaskAckPhase phase;
  final DateTime timestamp;
  final String? errorCode;
  final String? errorDetail;
  final int retryCount;

  PendingAck({
    required this.taskId,
    required this.phase,
    required this.timestamp,
    this.errorCode,
    this.errorDetail,
    this.retryCount = 0,
  });

  PendingAck copyWithIncrementRetry() {
    return PendingAck(
      taskId: taskId,
      phase: phase,
      timestamp: timestamp,
      errorCode: errorCode,
      errorDetail: errorDetail,
      retryCount: retryCount + 1,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'task_id': taskId,
      'phase': phase.value,
      'timestamp': timestamp.toIso8601String(),
      'error_code': errorCode,
      'error_detail': errorDetail,
      'retry_count': retryCount,
    };
  }

  factory PendingAck.fromJson(Map<String, dynamic> json) {
    return PendingAck(
      taskId: json['task_id'] as String,
      phase: TaskAckPhase.fromString(json['phase'] as String),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      errorCode: json['error_code'] as String?,
      errorDetail: json['error_detail'] as String?,
      retryCount: json['retry_count'] as int? ?? 0,
    );
  }

  static String encodeList(List<PendingAck> list) {
    return jsonEncode(list.map((e) => e.toJson()).toList());
  }

  static List<PendingAck> decodeList(String raw) {
    if (raw.isEmpty) return [];
    try {
      final List<dynamic> parsed = jsonDecode(raw) as List<dynamic>;
      return parsed
          .map((item) => PendingAck.fromJson(item as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
