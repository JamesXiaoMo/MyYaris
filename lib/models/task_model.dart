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
  final DateTime createdAt;
  final DateTime expiresAt;
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

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt.toUtc());

  /// Strict coordinate validation
  bool get hasValidCoordinates {
    return latitude >= -90.0 &&
        latitude <= 90.0 &&
        longitude >= -180.0 &&
        longitude <= 180.0;
  }

  /// Generates the standard geo URI as required: geo:0,0?q=lat,lon
  String toGeoUri() {
    return 'geo:0,0?q=$latitude,$longitude';
  }

  factory TaskModel.fromJson(Map<String, dynamic> json) {
    return TaskModel(
      taskId: json['task_id'] as String? ?? '',
      deviceId: json['device_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      address: json['address'] as String?,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      coordSystem: json['coord_system'] as String? ?? 'wgs84',
      status: json['status'] as String? ?? 'queued',
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc(),
      expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? '')?.toUtc() ??
          DateTime.now().toUtc().add(const Duration(hours: 1)),
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
      'created_at': createdAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
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
