import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'backend_client.dart';
import 'built_in_player_service.dart';
import 'in_app_audio_stream_proxy.dart';
import 'car_music_queue_controller.dart';
import '../models/music_queue_models.dart';

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

  int _statusSeq = 1;
  String? _lastAppliedCommandId;

  void start({
    required String baseUrl,
    required String deviceId,
    required String token,
    BackendClient? backendClient,
    Map<String, String>? fallbackDns,
    bool autoConnect = true,
  }) {
    if (_isRunning) stop();

    _baseUrl = baseUrl.trim();
    while (_baseUrl.endsWith('/')) {
      _baseUrl = _baseUrl.substring(0, _baseUrl.length - 1);
    }
    _deviceId = deviceId.trim();
    _token = token.trim();
    _backendClient = backendClient ??
        BackendClient(
          fallbackDns: (fallbackDns != null && fallbackDns.isNotEmpty)
              ? fallbackDns
              : null,
        );
    _isRunning = true;

    _playerService.setServerConfig(
      baseUrl: _baseUrl,
      token: _token,
    );
    CarMusicQueueController().configure(
      baseUrl: _baseUrl,
      token: _token,
      deviceId: _deviceId,
      backendClient: _backendClient,
    );

    if (autoConnect) {
      // Coldstart zero auto-play: load metadata in background, player remains stopped/paused
      if (CarMusicQueueController().tracks.isEmpty) {
        unawaited(CarMusicQueueController().loadFullFavoriteQueue());
      }

      InAppAudioStreamProxy().configure(
        backendClient: _backendClient,
        defaultToken: _token,
      );
      unawaited(InAppAudioStreamProxy().start());

      _listenToPlayerChanges();
      _connectWebSocket();
    }
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

    final queueCtrl = CarMusicQueueController();

    // 6. Transactional state backup for fail-closed rollback
    final backup = queueCtrl.createBackup();
    final wasPlaying = _playerService.player.playing;
    final prevPosition = _playerService.player.position;
    final prevActiveTrack = _playerService.activeRemoteTrack;

    // Prepared queue parameters (never fallback to expected preconditions!)
    final serverQueueId = (params['queue_id'] ?? params['prepared_queue_id'])?.toString();
    final serverQueueVersion = (params['queue_version'] ?? params['prepared_queue_version'] as num?)?.toInt();

    try {
      // Precondition assertions check (expected_queue_id & expected_queue_version)
      final expectedQueueId = params['expected_queue_id']?.toString();
      final expectedQueueVersion = (params['expected_queue_version'] as num?)?.toInt();
      if (expectedQueueId != null && expectedQueueId.isNotEmpty) {
        if (queueCtrl.queueId.isNotEmpty && queueCtrl.queueId != expectedQueueId) {
          throw BackendException(409, 'Precondition failed: expected_queue_id $expectedQueueId does not match active ${queueCtrl.queueId}');
        }
      }
      if (expectedQueueVersion != null && expectedQueueVersion > 0) {
        if (queueCtrl.queueVersion > 0 && queueCtrl.queueVersion != expectedQueueVersion) {
          throw BackendException(409, 'Precondition failed: expected_queue_version $expectedQueueVersion does not match active ${queueCtrl.queueVersion}');
        }
      }

      switch (action) {
        case 'set_playback_mode':
          final modeStr = (params['mode'] ?? params['playback_mode'])?.toString();
          final requestedMode = PlaybackMode.fromString(modeStr);

          // Determine target source: list_loop and shuffle MUST be netease_favorite!
          String targetSource;
          if (params['source'] != null && (params['source'] as String).isNotEmpty) {
            targetSource = params['source'].toString();
          } else if (requestedMode == PlaybackMode.intelligence) {
            targetSource = QueueSource.neteaseIntelligence;
          } else if (requestedMode == PlaybackMode.listLoop || requestedMode == PlaybackMode.shuffle) {
            targetSource = QueueSource.neteaseFavorite;
          } else if (requestedMode == PlaybackMode.singleLoop) {
            targetSource = queueCtrl.queueSource.isNotEmpty ? queueCtrl.queueSource : QueueSource.neteaseFavorite;
          } else {
            targetSource = queueCtrl.queueSource.isNotEmpty ? queueCtrl.queueSource : QueueSource.neteaseFavorite;
          }

          if (serverQueueId != null && serverQueueId.isNotEmpty) {
            if (serverQueueId != queueCtrl.queueId || (serverQueueVersion != null && serverQueueVersion != queueCtrl.queueVersion)) {
              final candidate = await queueCtrl.fetchAndValidateQueueSnapshot(
                queueId: serverQueueId,
                queueVersion: serverQueueVersion,
                source: targetSource,
              );
              if (candidate == null) {
                throw BackendException(500, 'Failed to load prepared queue $serverQueueId: ${queueCtrl.errorDetail}');
              }
              if (candidate.source != targetSource) {
                throw BackendException(422, 'Loaded snapshot source ${candidate.source} does not match target source $targetSource');
              }
              final candidateTrack = candidate.tracks.isNotEmpty ? candidate.tracks[0] : null;
              if (candidateTrack != null) {
                if (wasPlaying) {
                  if (candidateTrack.trackId != backup.currentTrack?.trackId) {
                    await _playerService.playQueueTrack(candidateTrack, startPlaying: true, rethrowOnError: true);
                  }
                } else {
                  await _playerService.playQueueTrack(candidateTrack, startPlaying: false, rethrowOnError: true);
                }
              }
              queueCtrl.applyQueueSnapshot(candidate, targetIndex: 0, mode: requestedMode);
              if (requestedMode == PlaybackMode.intelligence) {
                queueCtrl.setIntelligencePlaylistId((params['playlist_id'] as num?)?.toInt());
              }
            }
          } else if ((requestedMode == PlaybackMode.listLoop || requestedMode == PlaybackMode.shuffle) &&
              (queueCtrl.queueSource != QueueSource.neteaseFavorite || !queueCtrl.isFullyLoaded)) {
            final candidate = await queueCtrl.fetchAndValidateQueueSnapshot(source: QueueSource.neteaseFavorite);
            if (candidate == null) {
              throw BackendException(409, 'Favorite queue not fully ready for $modeStr: ${queueCtrl.errorDetail}');
            }
            final prevTrackId = backup.currentTrack?.trackId;
            final favIdx = candidate.tracks.indexWhere((t) => t.trackId == prevTrackId);
            final targetIdx = favIdx >= 0 ? favIdx : 0;
            final candidateTrack = candidate.tracks[targetIdx];

            if (wasPlaying) {
              if (candidateTrack.trackId != prevTrackId) {
                await _playerService.playQueueTrack(candidateTrack, startPlaying: true, rethrowOnError: true);
              }
            } else {
              if (candidateTrack.trackId != prevTrackId) {
                await _playerService.playQueueTrack(candidateTrack, startPlaying: false, rethrowOnError: true);
              }
            }
            queueCtrl.applyQueueSnapshot(candidate, targetIndex: targetIdx, mode: requestedMode);
          } else {
            final applied = queueCtrl.setPlaybackMode(requestedMode);
            if (!applied) {
              throw BackendException(422, 'Cannot apply playback mode ${requestedMode.value}');
            }
          }

          // Synchronize loop/shuffle mode on player engine
          if (requestedMode == PlaybackMode.singleLoop) {
            await _playerService.setLoopModeString('one');
          } else if (requestedMode == PlaybackMode.listLoop) {
            await _playerService.setLoopModeString('all');
            await _playerService.setShuffle(false);
          } else if (requestedMode == PlaybackMode.shuffle) {
            await _playerService.setShuffle(true);
          }
          break;

        case 'switch_queue':
          final source = params['source']?.toString() ?? QueueSource.neteaseFavorite;
          final startIndex = (params['start_index'] as num?)?.toInt() ?? 0;
          final startTrackId = params['start_track_id']?.toString();

          MusicQueueSnapshot? candidate;
          if (serverQueueId != null && serverQueueId.isNotEmpty) {
            candidate = await queueCtrl.fetchAndValidateQueueSnapshot(
              queueId: serverQueueId,
              queueVersion: serverQueueVersion,
              source: source,
            );
            if (candidate == null) {
              throw BackendException(500, 'Failed to switch queue to $serverQueueId: ${queueCtrl.errorDetail}');
            }
          } else if (source == QueueSource.neteaseFavorite) {
            candidate = await queueCtrl.fetchAndValidateQueueSnapshot(source: QueueSource.neteaseFavorite);
            if (candidate == null) {
              throw BackendException(500, 'Failed to load favorite queue: ${queueCtrl.errorDetail}');
            }
          } else {
            throw BackendException(422, 'switch_queue requires server queue_id for source $source');
          }

          if (candidate.source != source) {
            throw BackendException(422, 'Loaded snapshot source ${candidate.source} does not match target source $source');
          }

          int targetIdx = startIndex;
          if (startTrackId != null && startTrackId.isNotEmpty) {
            final found = candidate.tracks.indexWhere((t) => t.trackId == startTrackId);
            if (found >= 0) targetIdx = found;
          }
          targetIdx = targetIdx.clamp(0, candidate.tracks.isNotEmpty ? candidate.tracks.length - 1 : 0);

          if (candidate.tracks.isNotEmpty) {
            final targetTrack = candidate.tracks[targetIdx];
            await _playerService.playQueueTrack(targetTrack, startPlaying: wasPlaying, rethrowOnError: true);
          }
          queueCtrl.applyQueueSnapshot(candidate, targetIndex: targetIdx);
          break;

        case 'play_track':
        case 'play':
          final trackId = (params['track_id'] ?? params['song_id'])?.toString();
          final queueIndex = (params['queue_index'] as num?)?.toInt();
          final seekMs = (params['seek_ms'] ?? params['seek_position_ms'] ?? params['position_ms'] as num?)?.toInt() ?? 0;

          if (serverQueueId != null && serverQueueId.isNotEmpty) {
            String targetSource;
            if (params['source'] != null && (params['source'] as String).isNotEmpty) {
              targetSource = params['source'].toString();
            } else if (serverQueueId.startsWith('q_fav_')) {
              targetSource = QueueSource.neteaseFavorite;
            } else if (serverQueueId.startsWith('q_intel_')) {
              targetSource = QueueSource.neteaseIntelligence;
            } else if (serverQueueId.startsWith('q_single_')) {
              targetSource = QueueSource.singleTrack;
            } else {
              targetSource = queueCtrl.queueSource.isNotEmpty ? queueCtrl.queueSource : QueueSource.neteaseFavorite;
            }

            final candidate = await queueCtrl.fetchAndValidateQueueSnapshot(
              queueId: serverQueueId,
              queueVersion: serverQueueVersion,
              source: targetSource,
            );
            if (candidate == null) {
              throw BackendException(500, 'Failed to load prepared queue $serverQueueId: ${queueCtrl.errorDetail}');
            }
            if (candidate.source != targetSource) {
              throw BackendException(422, 'Loaded snapshot source ${candidate.source} does not match target source $targetSource');
            }

            int targetIdx = queueIndex ?? 0;
            if (trackId != null && trackId.isNotEmpty) {
              final found = candidate.tracks.indexWhere((t) => t.trackId == trackId);
              if (found >= 0) {
                targetIdx = found;
              } else {
                throw BackendException(404, 'Track $trackId not found in prepared queue $serverQueueId');
              }
            } else if (targetIdx < 0 || targetIdx >= candidate.tracks.length) {
              throw BackendException(404, 'Index $targetIdx out of bounds in prepared queue $serverQueueId');
            }

            final candidateTrack = candidate.tracks[targetIdx];
            await _playerService.playQueueTrack(
              candidateTrack,
              initialPosition: Duration(milliseconds: seekMs),
              startPlaying: true,
              rethrowOnError: true,
            );
            queueCtrl.applyQueueSnapshot(candidate, targetIndex: targetIdx);
          } else {
            // Controlled local test asset compatibility
            if (trackId != null && trackId.startsWith('local_')) {
              final localIdx = _playerService.tracks.indexWhere((t) => t.id == trackId);
              if (localIdx >= 0) {
                await _playerService.selectTrack(localIdx);
                break;
              }
            }

            int targetIdx = -1;
            if (trackId != null && queueCtrl.tracks.any((t) => t.trackId == trackId)) {
              targetIdx = queueCtrl.tracks.indexWhere((t) => t.trackId == trackId);
            } else if (queueIndex != null && queueIndex >= 0 && queueIndex < queueCtrl.tracks.length) {
              targetIdx = queueIndex;
            } else {
              throw BackendException(404, 'Track $trackId not found in active queue ${queueCtrl.queueId}');
            }

            queueCtrl.selectTrackByIndex(targetIdx);
            await _playerService.playQueueTrack(
              queueCtrl.currentTrack!,
              initialPosition: Duration(milliseconds: seekMs),
              startPlaying: true,
              rethrowOnError: true,
            );
          }
          break;

        case 'resume':
          final trackId = (params['track_id'] ?? params['song_id'])?.toString();
          final queueIndex = (params['queue_index'] as num?)?.toInt();
          final seekMs = (params['seek_ms'] ?? params['seek_position_ms'] ?? params['position_ms'] as num?)?.toInt() ?? 0;

          if (serverQueueId != null && serverQueueId.isNotEmpty) {
            String targetSource;
            if (params['source'] != null && (params['source'] as String).isNotEmpty) {
              targetSource = params['source'].toString();
            } else if (serverQueueId.startsWith('q_fav_')) {
              targetSource = QueueSource.neteaseFavorite;
            } else if (serverQueueId.startsWith('q_intel_')) {
              targetSource = QueueSource.neteaseIntelligence;
            } else if (serverQueueId.startsWith('q_single_')) {
              targetSource = QueueSource.singleTrack;
            } else {
              targetSource = queueCtrl.queueSource.isNotEmpty ? queueCtrl.queueSource : QueueSource.neteaseFavorite;
            }

            final candidate = await queueCtrl.fetchAndValidateQueueSnapshot(
              queueId: serverQueueId,
              queueVersion: serverQueueVersion,
              source: targetSource,
            );
            if (candidate == null) {
              throw BackendException(500, 'Failed to load prepared queue $serverQueueId on resume: ${queueCtrl.errorDetail}');
            }
            if (candidate.source != targetSource) {
              throw BackendException(422, 'Loaded snapshot source ${candidate.source} does not match target source $targetSource');
            }

            int targetIdx = queueIndex ?? 0;
            if (trackId != null && trackId.isNotEmpty) {
              final found = candidate.tracks.indexWhere((t) => t.trackId == trackId);
              if (found >= 0) targetIdx = found;
            }
            targetIdx = targetIdx.clamp(0, candidate.tracks.isNotEmpty ? candidate.tracks.length - 1 : 0);

            if (candidate.tracks.isNotEmpty) {
              final candidateTrack = candidate.tracks[targetIdx];
              await _playerService.playQueueTrack(
                candidateTrack,
                initialPosition: Duration(milliseconds: seekMs),
                startPlaying: true,
                rethrowOnError: true,
              );
            }
            queueCtrl.applyQueueSnapshot(candidate, targetIndex: targetIdx);
          } else if (queueCtrl.tracks.isEmpty) {
            // Cold queue: load default favorite queue
            final candidate = await queueCtrl.fetchAndValidateQueueSnapshot(source: QueueSource.neteaseFavorite);
            if (candidate == null || candidate.tracks.isEmpty) {
              throw BackendException(409, 'No active queue and failed to load favorite queue on resume: ${queueCtrl.errorDetail}');
            }
            int targetIdx = queueIndex ?? 0;
            if (trackId != null && trackId.isNotEmpty) {
              final found = candidate.tracks.indexWhere((t) => t.trackId == trackId);
              if (found >= 0) targetIdx = found;
            }
            targetIdx = targetIdx.clamp(0, candidate.tracks.length - 1);

            final candidateTrack = candidate.tracks[targetIdx];
            await _playerService.playQueueTrack(
              candidateTrack,
              initialPosition: Duration(milliseconds: seekMs),
              startPlaying: true,
              rethrowOnError: true,
            );
            queueCtrl.applyQueueSnapshot(candidate, targetIndex: targetIdx);
          } else {
            // Resuming active queue
            if (trackId != null && trackId.isNotEmpty) {
              final idx = queueCtrl.tracks.indexWhere((t) => t.trackId == trackId);
              if (idx < 0) throw BackendException(404, 'Track $trackId not found in active queue');
              queueCtrl.selectTrackByIndex(idx);
              await _playerService.playQueueTrack(
                queueCtrl.currentTrack!,
                initialPosition: Duration(milliseconds: seekMs),
                startPlaying: true,
                rethrowOnError: true,
              );
            } else if (queueIndex != null) {
              if (queueIndex < 0 || queueIndex >= queueCtrl.tracks.length) {
                throw BackendException(404, 'Index $queueIndex out of bounds');
              }
              queueCtrl.selectTrackByIndex(queueIndex);
              await _playerService.playQueueTrack(
                queueCtrl.currentTrack!,
                initialPosition: Duration(milliseconds: seekMs),
                startPlaying: true,
                rethrowOnError: true,
              );
            } else {
              if (seekMs > 0) {
                await _playerService.seek(Duration(milliseconds: seekMs));
              }
              if (_playerService.activeRemoteTrack == null && queueCtrl.currentTrack != null) {
                await _playerService.playQueueTrack(
                  queueCtrl.currentTrack!,
                  initialPosition: Duration(milliseconds: seekMs),
                  startPlaying: true,
                  rethrowOnError: true,
                );
              } else {
                await _playerService.play();
              }
            }
          }
          break;

        case 'pause':
          await _playerService.pause();
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
          final positionMs = (params['seek_position_ms'] ?? params['seek_ms'] ?? params['position_ms'] as num?)?.toInt() ?? 0;
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
        _lastAppliedCommandId = commandId;
        _commandHistory[commandId] = CommandHistoryEntry(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          status: 'applied',
        );
        _reportCommandAck(
          commandId,
          status: 'applied',
          appliedMode: queueCtrl.appliedMode.value,
          queueVersion: queueCtrl.queueVersion,
          currentIndex: queueCtrl.currentIndex,
          currentTrackId: queueCtrl.currentTrack?.trackId ?? _playerService.currentTrack.id,
        );
      }
      sendCurrentStatus();
    } catch (e) {
      debugPrint('[CarMusicSync] Error executing command $action: $e');
      lastCommandNotifier.value = '指令失败: $action ($e)';

      // TRANSACTIONAL ROLLBACK: Restore controller state and player
      queueCtrl.restoreBackup(backup);
      if (prevActiveTrack != null && _playerService.activeRemoteTrack?.id != prevActiveTrack.id) {
        try {
          final restoredTrack = backup.currentTrack;
          if (restoredTrack != null) {
            await _playerService.playQueueTrack(
              restoredTrack,
              initialPosition: prevPosition,
              startPlaying: wasPlaying,
            );
          }
        } catch (_) {}
      }
      if (!wasPlaying && _playerService.player.playing) {
        await _playerService.pause();
      }

      String errorCode = 'COMMAND_EXECUTION_ERROR';
      String errorDetail = e.toString();
      if (e is BackendException) {
        if (e.statusCode == 409) {
          errorCode = e.message.contains('Precondition') ? 'QUEUE_PRECONDITION_FAILED' : 'QUEUE_VERSION_CONFLICT';
        } else if (e.statusCode == 404) {
          errorCode = 'TRACK_NOT_FOUND';
        } else if (e.statusCode == 422) {
          errorCode = 'INVALID_QUEUE_PAYLOAD';
        }
        errorDetail = e.message;
      }

      if (commandId != null && commandId.isNotEmpty) {
        _commandHistory[commandId] = CommandHistoryEntry(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          status: 'failed',
          errorCode: errorCode,
          errorDetail: errorDetail,
        );
        _reportCommandAck(
          commandId,
          status: 'failed',
          errorCode: errorCode,
          errorDetail: errorDetail,
        );
      }
      sendCurrentStatus();
    } finally {
      if (commandId != null) {
        _executingCommands.remove(commandId);
      }
    }
  }

  void _reportCommandAck(
    String commandId, {
    required String status,
    String? appliedMode,
    int? queueVersion,
    int? currentIndex,
    String? currentTrackId,
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
          'applied_mode': ?appliedMode,
          'queue_version': ?queueVersion,
          'current_index': ?currentIndex,
          'current_track_id': ?currentTrackId,
          'error_code': errorCode,
          'error_detail': errorDetail,
          'device_timestamp': DateTime.now().toUtc().toIso8601String(),
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
        appliedMode: appliedMode,
        queueVersion: queueVersion,
        currentIndex: currentIndex,
        currentTrackId: currentTrackId,
        errorCode: errorCode,
        errorDetail: errorDetail,
      ).then((ok) {
        debugPrint('[CarMusicSync] Sent HTTP command_ack for $commandId (accepted=$ok)');
      }).catchError((err) {
        debugPrint('[CarMusicSync] Failed to send HTTP command_ack: $err');
      });
    }
  }

  /// Builds standard CarStatusReportRequest payload matching V2.2 backend schema
  Map<String, dynamic> _buildStatusData() {
    final player = _playerService.player;
    final isPlaying = player.playing;
    final stateStr = isPlaying ? 'playing' : (player.position > Duration.zero ? 'paused' : 'stopped');
    final curTrack = _playerService.currentTrack;
    final queueCtrl = CarMusicQueueController();

    final statusSeq = _statusSeq++;

    return {
      'device_id': _deviceId,
      'status_seq': statusSeq,
      'last_applied_command_id': _lastAppliedCommandId,
      'playback_state': stateStr,
      'applied_mode': queueCtrl.appliedMode.value,
      'requested_mode': queueCtrl.requestedMode.value,
      'queue_id': queueCtrl.queueId.isNotEmpty ? queueCtrl.queueId : null,
      'queue_version': queueCtrl.queueVersion > 0 ? queueCtrl.queueVersion : null,
      'queue_source': queueCtrl.queueSource,
      'current_index': queueCtrl.currentIndex,
      'current_track_id': curTrack.id,
      'title': curTrack.title,
      'artist': curTrack.artist,
      'position_ms': player.position.inMilliseconds,
      'duration_ms': player.duration?.inMilliseconds ?? 0,
      'software_volume': _playerService.currentVolume,
      'consecutive_failures': queueCtrl.consecutiveFailures,
      'error_code': queueCtrl.errorCode,
      'error_detail': queueCtrl.errorDetail,
      'capabilities': const [
        'queue_v2',
        'intelligence_v1',
        'full_favorite_shuffle',
      ],
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
