import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'backend_client.dart';
import 'built_in_player_service.dart';

enum MusicSyncMode {
  disconnected,
  websocket,
  httpPolling,
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
    final path = '/api/v1/ws/music';
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

      _webSocket = await WebSocket.connect(
        wsUri.toString(),
        headers: headers,
      ).timeout(const Duration(seconds: 8));

      _syncMode = MusicSyncMode.websocket;
      syncModeNotifier.value = _syncMode;
      debugPrint('[CarMusicSync] WebSocket connected successfully.');

      // Cancel fallback polling if running
      _pollingTimer?.cancel();
      _pollingTimer = null;

      // Broadcast initial status upon connection
      sendCurrentStatus();

      // Start periodic heartbeat
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

        // 1. Report status
        final statusPayload = _buildStatusPayload();
        await client.reportMusicStatus(
          baseUrl: _baseUrl,
          token: _token,
          status: statusPayload,
        );

        // 2. Poll for pending command
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

    // Sample position updates occasionally
    _positionSubscription?.cancel();
    _positionSubscription = _playerService.player.positionStream.listen((_) {
      // Sent on heartbeat or state transitions to prevent flooding socket
    });
  }

  void _handleIncomingMessage(dynamic raw) {
    try {
      final text = raw is List<int> ? utf8.decode(raw) : raw.toString();
      final json = jsonDecode(text) as Map<String, dynamic>;
      handleCommand(json);
    } catch (e) {
      debugPrint('[CarMusicSync] Failed to parse incoming message: $e');
    }
  }

  /// Public handler for remote commands (invoked from WebSocket or HTTP polling)
  Future<void> handleCommand(Map<String, dynamic> msg) async {
    final action = (msg['action'] as String? ?? msg['command'] as String? ?? '').toLowerCase().trim();
    final params = (msg['params'] as Map<String, dynamic>?) ?? msg;

    debugPrint('[CarMusicSync] Handling command: action=$action, params=$params');
    lastCommandNotifier.value = '收到指令: $action';

    try {
      switch (action) {
        case 'play_track':
        case 'play':
          final streamUrl = params['stream_url'] as String? ??
              (params['track_id'] != null
                  ? _backendClient?.buildLocalStreamUrl(_baseUrl, params['track_id'].toString())
                  : (params['song_id'] != null
                      ? _backendClient?.buildNeteaseStreamUrl(_baseUrl, params['song_id'].toString())
                      : null));

          if (streamUrl != null && streamUrl.isNotEmpty) {
            final trackId = (params['track_id'] ?? params['song_id'] ?? 'remote_1').toString();
            final title = params['title'] as String? ?? '远端点播曲目';
            final artist = params['artist'] as String? ?? 'R9000P 媒体库';
            final seekMs = params['seek_position_ms'] as int? ?? params['seek_ms'] as int? ?? 0;

            final headers = <String, String>{};
            if (_token.isNotEmpty) {
              headers['X-Device-Token'] = _token;
              headers['Authorization'] = 'Bearer $_token';
            }

            await _playerService.playRemoteStream(
              streamUrl,
              trackId: trackId,
              title: title,
              artist: artist,
              headers: headers,
              initialPosition: Duration(milliseconds: seekMs),
            );

            if (params['loop_mode'] != null) {
              await _playerService.setLoopModeString(params['loop_mode'].toString());
            }
            if (params['shuffle'] is bool) {
              await _playerService.setShuffle(params['shuffle'] as bool);
            }
          } else {
            await _playerService.play();
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
          final positionMs = params['seek_position_ms'] as int? ?? params['seek_ms'] as int? ?? params['position_ms'] as int? ?? 0;
          await _playerService.seek(Duration(milliseconds: positionMs));
          break;

        case 'set_volume':
          final vol = (params['volume'] as num?)?.toDouble() ?? 0.25;
          await _playerService.setVolume(vol);
          break;

        case 'set_loop':
        case 'set_loop_mode':
          final mode = params['loop_mode'] as String? ?? 'all';
          await _playerService.setLoopModeString(mode);
          break;

        case 'set_shuffle':
          final enabled = params['shuffle'] as bool? ?? false;
          await _playerService.setShuffle(enabled);
          break;

        default:
          debugPrint('[CarMusicSync] Unknown action: $action');
          break;
      }
      sendCurrentStatus();
    } catch (e) {
      debugPrint('[CarMusicSync] Error executing command $action: $e');
    }
  }

  Map<String, dynamic> _buildStatusPayload() {
    final player = _playerService.player;
    final isPlaying = player.playing;
    final stateStr = isPlaying ? 'playing' : (player.position > Duration.zero ? 'paused' : 'stopped');
    final curTrack = _playerService.currentTrack;

    return {
      'type': 'status_update',
      'device_id': _deviceId,
      'playback_state': stateStr,
      'current_track_id': curTrack.id,
      'title': curTrack.title,
      'artist': curTrack.artist,
      'position_ms': player.position.inMilliseconds,
      'duration_ms': player.duration?.inMilliseconds ?? 0,
      'software_volume': _playerService.currentVolume,
      'loop_mode': _playerService.currentLoopModeString,
      'shuffle': player.shuffleModeEnabled,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
  }

  /// Sends status payload over WebSocket or reports to backend
  void sendCurrentStatus() {
    if (!_isRunning) return;

    final payload = _buildStatusPayload();

    if (_syncMode == MusicSyncMode.websocket && _webSocket != null) {
      try {
        _webSocket!.add(jsonEncode(payload));
      } catch (e) {
        debugPrint('[CarMusicSync] Failed to send status over WebSocket: $e');
      }
    }
  }
}
