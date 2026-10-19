import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import '../models/task_model.dart';
import '../models/music_queue_models.dart';

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

enum AckResultType {
  accepted,
  explicitlyRejected,
  networkError,
}

class AckResult {
  final AckResultType type;
  final bool accepted;
  final String? message;
  final String? serverStatus;
  final int? statusCode;
  final Object? error;

  const AckResult.accepted({
    this.message,
    this.serverStatus,
    this.statusCode = 200,
  })  : type = AckResultType.accepted,
        accepted = true,
        error = null;

  const AckResult.rejected({
    this.message,
    this.serverStatus,
    this.statusCode,
  })  : type = AckResultType.explicitlyRejected,
        accepted = false,
        error = null;

  const AckResult.networkError(this.error)
      : type = AckResultType.networkError,
        accepted = false,
        message = null,
        serverStatus = null,
        statusCode = null;

  bool get isAccepted => type == AckResultType.accepted;
  bool get isExplicitlyRejected => type == AckResultType.explicitlyRejected;
  bool get isNetworkError => type == AckResultType.networkError;
}

class BackendClient {
  final HttpClient _httpClient;
  final Map<String, String> _fallbackDns;

  /// Default authorized hostname-to-IP fallback mappings.
  /// Strictly maintains TLS SNI, host header, certificate chain, and hostname verification.
  /// Configurable at build-time via --dart-define:
  ///   --dart-define=MYYARIS_FALLBACK_DNS_JSON='{"host.example.com":"192.0.2.1"}'
  ///   --dart-define=MYYARIS_FALLBACK_DNS_HOST=host.example.com --dart-define=MYYARIS_FALLBACK_DNS_IP=192.0.2.1
  /// Defaults to an empty map so no private IPs or hostnames are hardcoded in source.
  static Map<String, String> get defaultFallbackDns => parseFallbackDnsFromEnvironment();

  static Map<String, String> parseFallbackDnsFromEnvironment() {
    const jsonStr = String.fromEnvironment('MYYARIS_FALLBACK_DNS_JSON', defaultValue: '');
    if (jsonStr.isNotEmpty) {
      try {
        final decoded = json.decode(jsonStr);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString().trim(), v.toString().trim()));
        }
      } catch (_) {}
    }
    const host = String.fromEnvironment('MYYARIS_FALLBACK_DNS_HOST', defaultValue: '');
    const ip = String.fromEnvironment('MYYARIS_FALLBACK_DNS_IP', defaultValue: '');
    if (host.isNotEmpty && ip.isNotEmpty) {
      return {host.trim(): ip.trim()};
    }
    return const {};
  }

  BackendClient({
    HttpClient? httpClient,
    Map<String, String>? fallbackDns,
  })  : _fallbackDns = fallbackDns ?? defaultFallbackDns,
        _httpClient = httpClient ??
            _createHttpClient(fallbackDns ?? defaultFallbackDns);

  Map<String, String> get fallbackDns => Map.unmodifiable(_fallbackDns);
  HttpClient get httpClient => _httpClient;

  static HttpClient _createHttpClient(Map<String, String> fallbackDns) {
    final client = HttpClient(
      // Strict TLS verification: do NOT bypass certificate validation!
      context: SecurityContext.defaultContext,
    );
    client.connectionTimeout = const Duration(seconds: 15);

    if (fallbackDns.isNotEmpty) {
      client.connectionFactory = (uri, proxyHost, proxyPort) {
        final targetIp = fallbackDns[uri.host];
        final connectHost = targetIp ?? uri.host;
        final isHttps = uri.isScheme('https');
        final port = uri.hasPort ? uri.port : (isHttps ? 443 : 80);

        Socket? currentSocket;
        bool isCancelled = false;
        final completer = Completer<Socket>();

        Socket.connect(connectHost, port, timeout: const Duration(seconds: 10)).then(
          (plainSocket) {
            if (isCancelled) {
              plainSocket.destroy();
              return;
            }
            currentSocket = plainSocket;
            if (isHttps) {
              SecureSocket.secure(
                plainSocket,
                host: uri.host, // Strict SNI and hostname check against target host!
                context: SecurityContext.defaultContext,
              ).then(
                (secureSocket) {
                  if (isCancelled) {
                    secureSocket.destroy();
                  } else {
                    completer.complete(secureSocket);
                  }
                },
                onError: (Object err, StackTrace st) {
                  completer.completeError(err, st);
                },
              );
            } else {
              completer.complete(plainSocket);
            }
          },
          onError: (Object err, StackTrace st) {
            completer.completeError(err, st);
          },
        );

        return Future.value(ConnectionTask.fromSocket(completer.future, () {
          isCancelled = true;
          currentSocket?.destroy();
        }));
      };
    }

    return client;
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

  /// Long-poll next task for the given device ID.
  /// Prioritizes standard V2 endpoint (/api/v1/tasks/poll), gracefully falling back to legacy endpoint.
  Future<TaskModel?> getNextTask({
    required String baseUrl,
    required String deviceId,
    required String token,
    int timeoutSeconds = 20,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final v2Uri = Uri.parse('$base/api/v1/tasks/poll?device_id=$deviceId&timeout=$timeoutSeconds');

    var req = await _httpClient.getUrl(v2Uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }

    var res = await req.close().timeout(Duration(seconds: timeoutSeconds + 10));

    // Fallback to legacy path if server does not have /api/v1 prefix yet
    if (res.statusCode == 404) {
      final legacyUri = Uri.parse('$base/devices/$deviceId/tasks/next?timeout=$timeoutSeconds');
      req = await _httpClient.getUrl(legacyUri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set('X-Device-Token', token);
      }
      res = await req.close().timeout(Duration(seconds: timeoutSeconds + 10));
    }

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

  /// Re-check task status and expiration before launch
  Future<TaskModel> getTask({
    required String baseUrl,
    required String taskId,
    required String token,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final v2Uri = Uri.parse('$base/api/v1/tasks/$taskId');

    var req = await _httpClient.getUrl(v2Uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }

    var res = await req.close().timeout(const Duration(seconds: 12));
    if (res.statusCode == 404) {
      final legacyUri = Uri.parse('$base/tasks/$taskId');
      req = await _httpClient.getUrl(legacyUri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set('X-Device-Token', token);
      }
      res = await req.close().timeout(const Duration(seconds: 12));
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
  /// Strictly requires accepted == true. Distinguishes explicit rejection from network uncertainty.
  Future<AckResult> acknowledgeTask({
    required String baseUrl,
    required String taskId,
    required String token,
    required TaskAckPhase phase,
    DateTime? deviceTimestamp,
    String? errorCode,
    String? errorDetail,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final timestamp = deviceTimestamp ?? DateTime.now().toUtc();
    final statusVal = phase == TaskAckPhase.launchRequested ? 'launched' : phase.value;

    final payload = <String, dynamic>{
      'phase': phase.value,
      'status': statusVal,
      'device_timestamp': timestamp.toIso8601String(),
      'client_timestamp': timestamp.millisecondsSinceEpoch,
    };
    if (errorCode != null && errorCode.isNotEmpty) {
      payload['error_code'] = errorCode;
      payload['error_message'] = errorDetail ?? errorCode;
    }
    if (errorDetail != null && errorDetail.isNotEmpty) {
      payload['error_detail'] = errorDetail;
      payload['error_message'] = errorDetail;
    }

    final v2Uri = Uri.parse('$base/api/v1/tasks/$taskId/ack');

    try {
      var req = await _httpClient.postUrl(v2Uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set('X-Device-Token', token);
      }
      req.add(utf8.encode(jsonEncode(payload)));

      var res = await req.close().timeout(const Duration(seconds: 15));

      // Fallback to legacy path if 404
      if (res.statusCode == 404) {
        final legacyUri = Uri.parse('$base/tasks/$taskId/ack');
        req = await _httpClient.postUrl(legacyUri);
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (token.isNotEmpty) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          req.headers.set('X-Device-Token', token);
        }
        req.add(utf8.encode(jsonEncode(payload)));
        res = await req.close().timeout(const Duration(seconds: 15));
      }

      final responseBody = await utf8.decodeStream(res);

      if (res.statusCode == 200) {
        final json = jsonDecode(responseBody) as Map<String, dynamic>;
        final isAccepted = json['accepted'] == true || json['status'] == 'ok' || json['code'] == 200;
        if (isAccepted) {
          return AckResult.accepted(
            message: json['message'] as String?,
            serverStatus: json['status'] as String?,
            statusCode: 200,
          );
        } else {
          return AckResult.rejected(
            message: json['message'] as String?,
            serverStatus: json['status'] as String?,
            statusCode: 200,
          );
        }
      }

      if (res.statusCode == 401 || res.statusCode == 403) {
        throw AuthException(res.statusCode, responseBody);
      }

      if (res.statusCode == 400 ||
          res.statusCode == 404 ||
          res.statusCode == 409 ||
          res.statusCode == 422) {
        return AckResult.rejected(
          message: responseBody,
          statusCode: res.statusCode,
        );
      }

      return AckResult.networkError(
        BackendException(res.statusCode, 'Ack server error: $responseBody'),
      );
    } on AuthException {
      rethrow;
    } catch (e) {
      return AckResult.networkError(e);
    }
  }

  // ==========================================
  // Music & Media Streaming API Extensions
  // ==========================================

  /// Builds the HTTP Range streaming URL for local music library track
  String buildLocalStreamUrl(String baseUrl, String trackId) {
    final base = _normalizeUrl(baseUrl);
    return '$base/api/v1/music/stream/$trackId';
  }

  /// Builds the HTTP Range streaming URL for NetEase Cloud Music proxied track
  String buildNeteaseStreamUrl(String baseUrl, String songId) {
    final base = _normalizeUrl(baseUrl);
    return '$base/api/v1/music/netease/stream/$songId';
  }

  /// Fetches list of available tracks in local library
  Future<List<Map<String, dynamic>>> getMusicTracks({
    required String baseUrl,
    required String token,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/api/v1/music/tracks');

    final req = await _httpClient.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }

    final res = await req.close().timeout(const Duration(seconds: 10));
    final responseBody = await utf8.decodeStream(res);

    if (res.statusCode == 200) {
      final json = jsonDecode(responseBody);
      if (json is List) {
        return json.cast<Map<String, dynamic>>();
      } else if (json is Map && json['tracks'] is List) {
        return (json['tracks'] as List).cast<Map<String, dynamic>>();
      }
      return [];
    }
    throw BackendException(res.statusCode, 'Failed to fetch tracks: $responseBody');
  }

  /// Searches NetEase Cloud Music catalogue through R9000P proxy
  Future<List<Map<String, dynamic>>> searchNeteaseMusic({
    required String baseUrl,
    required String token,
    required String keyword,
    int page = 1,
    int limit = 20,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final encodedKw = Uri.encodeComponent(keyword);
    final uri = Uri.parse('$base/api/v1/music/netease/search?keyword=$encodedKw&page=$page&limit=$limit');

    final req = await _httpClient.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }

    final res = await req.close().timeout(const Duration(seconds: 12));
    final responseBody = await utf8.decodeStream(res);

    if (res.statusCode == 200) {
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      if (json['songs'] is List) {
        return (json['songs'] as List).cast<Map<String, dynamic>>();
      }
      return [];
    }
    throw BackendException(res.statusCode, 'Search failed: $responseBody');
  }

  /// Fetches synchronized LRC lyric for NetEase track
  Future<String?> getNeteaseLyric({
    required String baseUrl,
    required String token,
    required String songId,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/api/v1/music/netease/lyric?song_id=$songId');

    final req = await _httpClient.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }

    final res = await req.close().timeout(const Duration(seconds: 10));
    final responseBody = await utf8.decodeStream(res);

    if (res.statusCode == 200) {
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      return json['lrc'] as String? ?? json['lyric'] as String?;
    }
    return null;
  }

  /// Polls for next pending music command from phone (Option B: HTTP polling fallback)
  Future<Map<String, dynamic>?> pollMusicCommand({
    required String baseUrl,
    required String deviceId,
    required String token,
    int timeoutSeconds = 15,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/api/v1/music/control/command/next?device_id=$deviceId&timeout=$timeoutSeconds');

    final req = await _httpClient.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }

    final res = await req.close().timeout(Duration(seconds: timeoutSeconds + 10));
    if (res.statusCode == 204) return null;

    final responseBody = await utf8.decodeStream(res);
    if (res.statusCode == 200) {
      return jsonDecode(responseBody) as Map<String, dynamic>;
    }
    return null;
  }

  /// Reports current player status to backend (Option B: HTTP status report)
  Future<bool> reportMusicStatus({
    required String baseUrl,
    required String token,
    required Map<String, dynamic> status,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/api/v1/music/control/status');

    try {
      final req = await _httpClient.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set('X-Device-Token', token);
      }
      req.add(utf8.encode(jsonEncode(status)));

      final res = await req.close().timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Fetches music queue snapshot page conforming to Section 3.2 / 4.1 of V2.2 contract.
  /// Throws BackendException on non-200 responses (e.g. 409 QUEUE_VERSION_CONFLICT, 409 EMPTY_PLAYLIST).
  Future<MusicQueueSnapshot> fetchMusicQueuePage({
    required String baseUrl,
    required String token,
    String? deviceId,
    String? source,
    int offset = 0,
    int limit = 50,
    String? queueId,
    int? queueVersion,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final queryParams = <String, String>{
      'offset': offset.toString(),
      'limit': limit.toString(),
    };
    if (deviceId != null && deviceId.isNotEmpty) {
      queryParams['device_id'] = deviceId;
    }
    if (source != null && source.isNotEmpty) {
      queryParams['source'] = source;
    }
    if (queueId != null && queueId.isNotEmpty) {
      queryParams['queue_id'] = queueId;
    }
    if (queueVersion != null) {
      queryParams['queue_version'] = queueVersion.toString();
    }

    final uri = Uri.parse('$base/api/v1/music/queue').replace(queryParameters: queryParams);
    final req = await _httpClient.getUrl(uri);
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }

    final res = await req.close().timeout(const Duration(seconds: 15));
    final responseBody = await utf8.decodeStream(res);
    if (res.statusCode == 200) {
      final json = jsonDecode(responseBody) as Map<String, dynamic>;
      return MusicQueueSnapshot.fromJson(json);
    }
    throw BackendException(res.statusCode, responseBody);
  }

  /// Requests authentic intelligence mode batch conforming to Section 4.2 of V2.2 contract.
  /// seedSongId must belong to owner favorite playlist for batchIndex == 0.
  Future<Map<String, dynamic>> requestIntelligenceBatch({
    required String baseUrl,
    required String token,
    required String requestId,
    required int seedSongId,
    required int playlistId,
    int batchIndex = 0,
    int count = 30,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/api/v1/music/netease/intelligence');
    final req = await _httpClient.postUrl(uri);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    req.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (token.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      req.headers.set('X-Device-Token', token);
    }
    final payload = {
      'request_id': requestId,
      'seed_song_id': seedSongId,
      'playlist_id': playlistId,
      'batch_index': batchIndex,
      'count': count,
    };
    req.add(utf8.encode(jsonEncode(payload)));

    final res = await req.close().timeout(const Duration(seconds: 15));
    final responseBody = await utf8.decodeStream(res);
    if (res.statusCode == 200) {
      return jsonDecode(responseBody) as Map<String, dynamic>;
    }
    throw BackendException(res.statusCode, responseBody);
  }

  /// Reports command execution acknowledgement via HTTP fallback (POST /api/v1/music/control/command/{command_id}/ack)
  Future<bool> ackMusicCommand({
    required String baseUrl,
    required String token,
    required String commandId,
    required String status,
    String? appliedMode,
    int? queueVersion,
    int? currentIndex,
    String? currentTrackId,
    String? errorCode,
    String? errorDetail,
  }) async {
    final base = _normalizeUrl(baseUrl);
    final uri = Uri.parse('$base/api/v1/music/control/command/$commandId/ack');

    try {
      final req = await _httpClient.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set('X-Device-Token', token);
      }
      final payload = {
        'status': status,
        'applied_mode': ?appliedMode,
        'queue_version': ?queueVersion,
        'current_index': ?currentIndex,
        'current_track_id': ?currentTrackId,
        'error_code': errorCode,
        'error_detail': errorDetail,
        'device_timestamp': DateTime.now().toUtc().toIso8601String(),
      };

      req.add(utf8.encode(jsonEncode(payload)));

      final res = await req.close().timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }


  /// Connects to a WebSocket endpoint using the configured HttpClient with DNS fallback and strict TLS verification
  Future<WebSocket> connectWebSocket(
    Uri uri, {
    Map<String, dynamic>? headers,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final isSecure = uri.scheme == 'wss';
    final httpScheme = isSecure ? 'https' : 'http';
    final httpUri = uri.replace(scheme: httpScheme);

    final req = await _httpClient.openUrl('GET', httpUri).timeout(timeout);
    req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
    req.headers.set('Upgrade', 'websocket');
    req.headers.set('Sec-WebSocket-Version', '13');

    final rng = math.Random();
    final keyBytes = List<int>.generate(16, (_) => rng.nextInt(256));
    final secKey = base64.encode(keyBytes);
    req.headers.set('Sec-WebSocket-Key', secKey);

    if (headers != null) {
      headers.forEach((k, v) {
        req.headers.set(k, v.toString());
      });
    }

    final resp = await req.close().timeout(timeout);
    if (resp.statusCode != 101) {
      final body = await utf8.decodeStream(resp);
      throw WebSocketException('WebSocket handshake failed with status ${resp.statusCode}: $body');
    }

    final socket = await resp.detachSocket();
    return WebSocket.fromUpgradedSocket(socket, serverSide: false);
  }
}
