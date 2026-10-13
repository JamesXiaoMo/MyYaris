import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'backend_client.dart';
import 'built_in_player_service.dart';
import 'in_app_audio_stream_proxy.dart';

enum MusicSyncMode {
  disconnected,
  websocket,
  httpPolling,
}

class CommandHistoryEntry {
  final int timestamp;
  final String status;
  final String? errorCode;
  final String? errorDetail;

  CommandHistoryEntry({
    required this.timestamp,
    required this.status,
    this.errorCode,
    this.errorDetail,
  });
}

class CarMusicSyncService {
  static final CarMusicSyncService _instance = CarMusicSyncService._internal();
  factory CarMusicSyncService() => _instance;
  CarMusicSyncService._internal();

  final BuiltInPlayerService _playerService = BuiltInPlayerService();
  BackendClient? _backendClient;

  WebSocket? _webSocket;
  Timer? _reconnectTimer;
  Timer? _pollingTimer;
  Timer? _statusHeartbeatTimer;
  StreamSubscription? _playerStateSubscription;
  StreamSubscription? _positionSubscription;

  bool _isRunning = false;
  bool get isRunning => _isRunning;

  MusicSyncMode _syncMode = MusicSyncMode.disconnected;
  MusicSyncMode get syncMode => _syncMode;

  String _baseUrl = '';
  String _deviceId = '';
  String _token = '';

  final ValueNotifier<MusicSyncMode> syncModeNotifier = ValueNotifier(MusicSyncMode.disconnected);
  final ValueNotifier<String> lastCommandNotifier = ValueNotifier('就绪 (Ready)');

  // Cross-channel command_id deduplication & result cache: commandId -> CommandHistoryEntry
  final Map<String, CommandHistoryEntry> _commandHistory = {};
  final Set<String> _executingCommands = {};

  void start({
    required String baseUrl,
    required String deviceId,
    required String token,
    BackendClient? backendClient,
  }) {
    if (_isRunning) stop();

    _baseUrl = baseUrl.trim();
    while (_baseUrl.endsWith('/')) {
      _baseUrl = _baseUrl.substring(0, _baseUrl.length - 1);
    }
    _deviceId = deviceId.trim();
    _token = token.trim();
    _backendClient = backendClient ?? BackendClient();
    _isRunning = true;

    InAppAudioStreamProxy().configure(
      backendClient: _backendClient,
      defaultToken: _token,
    );
    unawaited(InAppAudioStreamProxy().start());

    _listenToPlayerChanges();
    _connectWebSocket();
  }

  void stop() {
    _isRunning = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _statusHeartbeatTimer?.cancel();
    _statusHeartbeatTimer = null;

    _playerStateSubscription?.cancel();
    _playerStateSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;

    try {
      _webSocket?.close();
    } catch (_) {}
    _webSocket = null;

    _syncMode = MusicSyncMode.disconnected;
    syncModeNotifier.value = _syncMode;
  }

  /// Builds WebSocket URL: wss://.../api/v1/ws/music?token=...&client_type=car&device_id=...
  Uri _buildWebSocketUri() {
    final baseUri = Uri.parse(_baseUrl);
    final wsScheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    const path = '/api/v1/ws/music';
    final queryParams = <String, String>{
      'client_type': 'car',
      'device_id': _deviceId,
    };
    if (_token.isNotEmpty) {
      queryParams['token'] = _token;
    }

    return Uri(
      scheme: wsScheme,
      host: baseUri.host,
      port: baseUri.hasPort ? baseUri.port : (wsScheme == 'wss' ? 443 : 80),
      path: path,
      queryParameters: queryParams,
    );
  }

  Future<void> _connectWebSocket() async {
    if (!_isRunning) return;

    final wsUri = _buildWebSocketUri();
    debugPrint('[CarMusicSync] Connecting WebSocket: $wsUri');

    try {
      final headers = <String, dynamic>{
        'client_type': 'car',
        'X-Device-Token': _token,
      };

      final client = _backendClient;
      if (client != null) {
        _webSocket = await client.connectWebSocket(
          wsUri,
          headers: headers,
          timeout: const Duration(seconds: 8),
        );
      } else {
        _webSocket = await WebSocket.connect(
          wsUri.toString(),
          headers: headers,
        ).timeout(const Duration(seconds: 8));
      }

      _syncMode = MusicSyncMode.websocket;
      syncModeNotifier.value = _syncMode;
      debugPrint('[CarMusicSync] WebSocket connected successfully.');

      // Cancel fallback polling if running
      _pollingTimer?.cancel();
      _pollingTimer = null;

      // Broadcast initial status upon connection
      sendCurrentStatus();

      // Start periodic status broadcast / heartbeat
      _statusHeartbeatTimer?.cancel();
      _statusHeartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        sendCurrentStatus();
      });

      _webSocket!.listen(
        (data) {
          _handleIncomingMessage(data);
        },
        onError: (err) {
          debugPrint('[CarMusicSync] WebSocket error: $err');
          _onWebSocketDisconnected();
        },
        onDone: () {
          debugPrint('[CarMusicSync] WebSocket closed.');
          _onWebSocketDisconnected();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('[CarMusicSync] WebSocket connect failed: $e. Falling back to HTTP polling.');
      _onWebSocketDisconnected();
    }
  }

  void _onWebSocketDisconnected() {
    _webSocket = null;
    if (!_isRunning) return;

    // Switch to HTTP Polling fallback mode
    if (_syncMode != MusicSyncMode.httpPolling) {
      _syncMode = MusicSyncMode.httpPolling;
      syncModeNotifier.value = _syncMode;
      _startHttpPollingFallback();
    }

    // Schedule WebSocket reconnect after 10 seconds
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 10), () {
      if (_isRunning && _webSocket == null) {
        _connectWebSocket();
      }
    });
  }

  /// Option B: HTTP Polling loop when WebSocket is temporarily unavailable
  void _startHttpPollingFallback() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_isRunning || _syncMode != MusicSyncMode.httpPolling) return;
      try {
        final client = _backendClient;
        if (client == null) return;

        // 1. Report current status via HTTP
        final statusData = _buildStatusData();
        await client.reportMusicStatus(
          baseUrl: _baseUrl,
          token: _token,
          status: statusData,
        );

        // 2. Poll for pending command via HTTP
        final cmd = await client.pollMusicCommand(
          baseUrl: _baseUrl,
          deviceId: _deviceId,
          token: _token,
          timeoutSeconds: 4,
        );
        if (cmd != null) {
          await handleCommand(cmd);
        }
      } catch (e) {
        debugPrint('[CarMusicSync] HTTP Polling error: $e');
      }
    });
  }

  void _listenToPlayerChanges() {
    _playerStateSubscription?.cancel();
    _playerStateSubscription = _playerService.player.playerStateStream.listen((_) {
      sendCurrentStatus();
    });

    _positionSubscription?.cancel();
    _positionSubscription = _playerService.player.positionStream.listen((_) {
      // Sent on state transitions or heartbeat to avoid flooding socket
    });
  }

  void _handleIncomingMessage(dynamic raw) {
    try {
      final text = raw is List<int> ? utf8.decode(raw) : raw.toString();
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) {
        final msgType = json['type'] as String?;
        if (msgType == 'pong') {
          // Server pong response
          return;
        }
        if (msgType == 'status_snapshot') {
          debugPrint('[CarMusicSync] Received initial status snapshot from server.');
          return;
        }
        if (msgType == 'status_update') {
          // Broadcast echo, ignore
          return;
        }
        handleCommand(json);
      }
    } catch (e) {
      debugPrint('[CarMusicSync] Failed to parse incoming message: $e');
    }
  }

  /// Prune expired command IDs from deduplication cache (10 min TTL, max 500 entries)
  void _pruneExpiredCommands() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _commandHistory.removeWhere((_, entry) => now - entry.timestamp > 600000);
    if (_commandHistory.length > 500) {
      final sortedKeys = _commandHistory.keys.toList()
        ..sort((a, b) => _commandHistory[a]!.timestamp.compareTo(_commandHistory[b]!.timestamp));
      final toRemove = sortedKeys.take(_commandHistory.length - 500);
      for (final k in toRemove) {
        _commandHistory.remove(k);
      }
    }
  }

  /// Public handler for remote commands (invoked from WebSocket or HTTP polling fallback)
  Future<void> handleCommand(Map<String, dynamic> rawMsg) async {
    // 1. Unpack envelope: support {"type": "music_command", "data": {...}} and root {...}
    final Map<String, dynamic> cmdData = (rawMsg['data'] is Map<String, dynamic>)
        ? rawMsg['data'] as Map<String, dynamic>
        : rawMsg;

    // 2. Extract action and reject if empty
    final action = (cmdData['action'] as String? ??
            cmdData['command'] as String? ??
            rawMsg['action'] as String? ??
            rawMsg['command'] as String? ??
            '')
        .toLowerCase()
        .trim();

    final commandId = (cmdData['command_id'] ?? rawMsg['command_id'])?.toString();

    if (action.isEmpty) {
      debugPrint('[CarMusicSync] Rejected command with empty action. (command_id: $commandId)');
      return;
    }

    // 3. TTL / expiration check
    final expiresAtStr = (cmdData['expires_at'] ?? rawMsg['expires_at'])?.toString();
    if (expiresAtStr != null && expiresAtStr.isNotEmpty) {
      // Backend ISO format is in UTC; append Z if timezone offset is absent so Dart parses as UTC
      final normalizedExpiry = (expiresAtStr.endsWith('Z') || expiresAtStr.contains('+'))
          ? expiresAtStr
          : '${expiresAtStr}Z';
      final expiry = DateTime.tryParse(normalizedExpiry);
      if (expiry != null && DateTime.now().toUtc().isAfter(expiry)) {
        debugPrint('[CarMusicSync] Stale command ignored: command_id=$commandId expired at $expiresAtStr');
        if (commandId != null && commandId.isNotEmpty) {
          _reportCommandAck(
            commandId,
            status: 'failed',
            errorCode: 'COMMAND_EXPIRED',
            errorDetail: 'Command expired at $expiresAtStr',
          );
        }
        return;
      }
    }

    // 4. Deduplicate across dual channels & protect against concurrent duplicates
    if (commandId != null && commandId.isNotEmpty) {
      _pruneExpiredCommands();

      if (_executingCommands.contains(commandId)) {
        debugPrint('[CarMusicSync] Command "$commandId" is currently executing. Concurrent duplicate dropped.');
        return;
      }

      final existing = _commandHistory[commandId];
      if (existing != null) {
        debugPrint('[CarMusicSync] Duplicate command_id "$commandId" received. Re-sending cached ack (status=${existing.status}) without re-executing.');
        _reportCommandAck(
          commandId,
          status: existing.status,
          errorCode: existing.errorCode,
          errorDetail: existing.errorDetail,
        );
        return;
      }

      _executingCommands.add(commandId);
      _reportCommandAck(commandId, status: 'received');
    }

    // 5. Extract parameters
    Map<String, dynamic> params;
    if (cmdData['params'] is Map<String, dynamic>) {
      params = cmdData['params'] as Map<String, dynamic>;
    } else {
      params = cmdData;
    }

    debugPrint('[CarMusicSync] Executing command: action=$action, command_id=$commandId, params=$params');
    lastCommandNotifier.value = '收到指令: $action';

    try {
      switch (action) {
        case 'play_track':
        case 'play':
          final trackId = (params['track_id'] ?? params['song_id'])?.toString();
          String? streamUrl = params['stream_url'] as String?;

          // Check if trackId matches a local built-in offline asset track
          final localIdx = _playerService.tracks.indexWhere((t) => t.id == trackId);
          if (localIdx >= 0 && (streamUrl == null || streamUrl.isEmpty)) {
            await _playerService.selectTrack(localIdx);
          } else {
            // If streamUrl not directly provided, build stream URL via BackendClient
            if (streamUrl == null || streamUrl.isEmpty) {
              if (params['song_id'] != null || (trackId != null && trackId.startsWith('netease_'))) {
                final sid = params['song_id']?.toString() ?? trackId!.replaceFirst('netease_', '');
                streamUrl = _backendClient?.buildNeteaseStreamUrl(_baseUrl, sid);
              } else if (trackId != null && trackId.isNotEmpty) {
                streamUrl = _backendClient?.buildLocalStreamUrl(_baseUrl, trackId);
              }
            }

            if (streamUrl != null && streamUrl.isNotEmpty) {
              final title = params['title'] as String? ?? '远端点播曲目';
              final artist = params['artist'] as String? ?? 'R9000P 媒体库';
              final seekMs = params['seek_ms'] as int? ??
                  params['seek_position_ms'] as int? ??
                  params['position_ms'] as int? ??
                  0;

              final headers = <String, String>{};
              if (_token.isNotEmpty) {
                headers['X-Device-Token'] = _token;
                headers['Authorization'] = 'Bearer $_token';
              }

              await _playerService.playRemoteStream(
                streamUrl,
                trackId: trackId ?? 'remote_stream',
                title: title,
                artist: artist,
                headers: headers,
                initialPosition: Duration(milliseconds: seekMs),
              );
            } else {
              await _playerService.play();
            }
          }

          if (params['loop_mode'] != null || params['mode'] != null) {
            final mode = (params['loop_mode'] ?? params['mode']).toString();
            await _playerService.setLoopModeString(mode);
          }
          if (params['shuffle'] is bool) {
            await _playerService.setShuffle(params['shuffle'] as bool);
          }
          break;

        case 'pause':
          await _playerService.pause();
          break;

        case 'resume':
          await _playerService.play();
          break;

        case 'stop':
          await _playerService.stop();
          break;

        case 'next':
          await _playerService.skipToNext();
          break;

        case 'prev':
        case 'previous':
          await _playerService.skipToPrevious();
          break;

        case 'seek':
          final positionMs = params['seek_ms'] as int? ??
              params['seek_position_ms'] as int? ??
              params['position_ms'] as int? ??
              0;
          await _playerService.seek(Duration(milliseconds: positionMs));
          break;

        case 'set_volume':
          final vol = (params['volume'] as num?)?.toDouble() ?? 0.25;
          await _playerService.setVolume(vol);
          break;

        case 'set_loop':
        case 'set_loop_mode':
          final mode = (params['loop_mode'] ?? params['mode'] ?? 'all').toString();
          await _playerService.setLoopModeString(mode);
          break;

        case 'set_shuffle':
          final enabled = params['shuffle'] as bool? ?? params['enabled'] as bool? ?? false;
          await _playerService.setShuffle(enabled);
          break;

        default:
          debugPrint('[CarMusicSync] Unknown action ignored: $action');
          break;
      }

      if (commandId != null && commandId.isNotEmpty) {
        _commandHistory[commandId] = CommandHistoryEntry(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          status: 'applied',
        );
        _reportCommandAck(commandId, status: 'applied');
      }
      sendCurrentStatus();
    } catch (e) {
      debugPrint('[CarMusicSync] Error executing command $action: $e');
      if (commandId != null && commandId.isNotEmpty) {
        _commandHistory[commandId] = CommandHistoryEntry(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          status: 'failed',
          errorCode: 'COMMAND_EXECUTION_ERROR',
          errorDetail: e.toString(),
        );
        _reportCommandAck(
          commandId,
          status: 'failed',
          errorCode: 'COMMAND_EXECUTION_ERROR',
          errorDetail: e.toString(),
        );
      }
    } finally {
      if (commandId != null) {
        _executingCommands.remove(commandId);
      }
    }
  }

  void _reportCommandAck(
    String commandId, {
    required String status,
    String? errorCode,
    String? errorDetail,
  }) {
    if (!_isRunning) return;

    if (_syncMode == MusicSyncMode.websocket && _webSocket != null) {
      try {
        final ackPayload = {
          'type': 'command_ack',
          'command_id': commandId,
          'status': status,
          'error_code': errorCode,
          'error_detail': errorDetail,
        };
        _webSocket!.add(jsonEncode(ackPayload));
        debugPrint('[CarMusicSync] Sent WebSocket command_ack for $commandId (status=$status)');
      } catch (e) {
        debugPrint('[CarMusicSync] Failed to send command_ack over WebSocket: $e');
      }
    } else if (_backendClient != null && _baseUrl.isNotEmpty) {
      _backendClient!.ackMusicCommand(
        baseUrl: _baseUrl,
        token: _token,
        commandId: commandId,
        status: status,
        errorCode: errorCode,
        errorDetail: errorDetail,
      ).then((ok) {
        debugPrint('[CarMusicSync] Sent HTTP command_ack for $commandId (accepted=$ok)');
      }).catchError((err) {
        debugPrint('[CarMusicSync] Failed to send HTTP command_ack: $err');
      });
    }
  }

  /// Builds standard CarStatusReportRequest payload matching backend schema
  Map<String, dynamic> _buildStatusData() {
    final player = _playerService.player;
    final isPlaying = player.playing;
    final stateStr = isPlaying ? 'playing' : (player.position > Duration.zero ? 'paused' : 'stopped');
    final curTrack = _playerService.currentTrack;

    return {
      'device_id': _deviceId,
      'playback_state': stateStr,
      'current_track_id': curTrack.id,
      'position_ms': player.position.inMilliseconds,
      'duration_ms': player.duration?.inMilliseconds ?? 0,
      'software_volume': _playerService.currentVolume,
      'loop_mode': _playerService.currentLoopModeString,
      'shuffle': player.shuffleModeEnabled,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Sends status payload over WebSocket wrapped in {"type": "status_update", "data": {...}}
  void sendCurrentStatus() {
    if (!_isRunning) return;

    final statusData = _buildStatusData();

    if (_syncMode == MusicSyncMode.websocket && _webSocket != null) {
      try {
        final envelope = {
          'type': 'status_update',
          'data': statusData,
        };
        _webSocket!.add(jsonEncode(envelope));
      } catch (e) {
        debugPrint('[CarMusicSync] Failed to send status over WebSocket: $e');
      }
    }
  }
}
