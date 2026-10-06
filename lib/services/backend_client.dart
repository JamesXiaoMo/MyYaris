import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/task_model.dart';

class AuthException implements Exception {
  final int statusCode;
  final String message;
  AuthException(this.statusCode, this.message);
  @override
  String toString() => 'AuthException($statusCode): $message';
}

class BackendException implements Exception {
  final int statusCode;
  final String message;
  BackendException(this.statusCode, this.message);
  @override
  String toString() => 'BackendException($statusCode): $message';
}

class BackendClient {
  final HttpClient _httpClient;

  BackendClient({HttpClient? httpClient})
      : _httpClient = httpClient ??
            HttpClient(
              // Strict TLS verification: do NOT bypass certificate validation!
              context: SecurityContext.defaultContext,
            ) {
    _httpClient.connectionTimeout = const Duration(seconds: 15);
  }

  void close() {
    _httpClient.close(force: true);
  }

  /// Normalizes base URL, stripping trailing slashes
  String _normalizeUrl(String url) {
    var trimmed = url.trim();
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  /// Check server health
  Future<bool> checkHealth(String baseUrl) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/health');
    try {
      final req = await _httpClient.getUrl(uri).timeout(const Duration(seconds: 8));
      final res = await req.close().timeout(const Duration(seconds: 8));
      final body = await utf8.decodeStream(res);
      if (res.statusCode == 200) {
        final data = jsonDecode(body) as Map<String, dynamic>;
        return data['status'] == 'ok' || data.containsKey('status');
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Long-poll next task for the given device ID
  Future<TaskModel?> getNextTask({
    required String baseUrl,
    required String deviceId,
    required String token,
    int timeoutSeconds = 20,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/devices/$deviceId/tasks/next?timeout=$timeoutSeconds');

    final req = await _httpClient.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }

    // Set HTTP socket timeout slightly longer than long-poll timeout to allow response
    final res = await req.close().timeout(Duration(seconds: timeoutSeconds + 10));

    if (res.statusCode == 204) {
      // 204 No Content: Long poll timeout reached on server side, no task queued
      return null;
    }

    final responseBody = await utf8.decodeStream(res);

    if (res.statusCode == 200) {
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      return TaskModel.fromJson(json);
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw AuthException(res.statusCode, responseBody);
    }

    throw BackendException(res.statusCode, 'Failed to fetch task: $responseBody');
  }

  /// Acknowledge task phase (received, launch_requested, failed)
  Future<bool> acknowledgeTask({
    required String baseUrl,
    required String taskId,
    required String token,
    required TaskAckPhase phase,
    DateTime? deviceTimestamp,
    String? errorCode,
    String? errorDetail,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/tasks/$taskId/ack');

    final payload = <String, dynamic>{
      'phase': phase.value,
      'device_timestamp': (deviceTimestamp ?? DateTime.now().toUtc()).toIso8601String(),
    };
    if (errorCode != null && errorCode.isNotEmpty) {
      payload['error_code'] = errorCode;
    }
    if (errorDetail != null && errorDetail.isNotEmpty) {
      payload['error_detail'] = errorDetail;
    }

    final req = await _httpClient.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }

    req.add(utf8.encode(jsonEncode(payload)));

    final res = await req.close().timeout(const Duration(seconds: 15));
    final responseBody = await utf8.decodeStream(res);

    if (res.statusCode == 200) {
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      return json['accepted'] == true || json.containsKey('status');
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw AuthException(res.statusCode, responseBody);
    }

    throw BackendException(res.statusCode, 'Ack failed: $responseBody');
  }
}
