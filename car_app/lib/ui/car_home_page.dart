import 'package:flutter/material.dart';
import '../services/car_music_sync_service.dart';
import '../services/music_service.dart';
import '../services/storage_service.dart';
import '../services/task_poller_service.dart';
import 'connection_debug_page.dart';
import 'built_in_player_page.dart';
import 'obd_dashboard_page.dart';
import '../models/obd_telemetry.dart';
import '../services/car_obd_service.dart';

class CarHomePage extends StatefulWidget {
  final IStorageService storage;
  final TaskPollerService poller;

  const CarHomePage({
    super.key,
    required this.storage,
    required this.poller,
  });

  @override
  State<CarHomePage> createState() => _CarHomePageState();
}

class _CarHomePageState extends State<CarHomePage> {
  final MusicService _musicService = MusicService();

  bool _hasNotificationPermission = false;
  PlaybackInfo? _playbackInfo;
  bool _isLoadingInfo = false;

  @override
  void initState() {
    super.initState();
    // Maintain poller running state across navigation
    if (widget.storage.isPollingEnabled && !widget.poller.isRunning) {
      widget.poller.start();
    }
    if (widget.storage.backendUrl.isNotEmpty &&
        !widget.storage.backendUrl.contains('mock') &&
        !CarMusicSyncService().isRunning) {
      CarMusicSyncService().start(
        baseUrl: widget.storage.backendUrl,
        deviceId: widget.storage.deviceId,
        token: widget.storage.carToken,
        fallbackDns: widget.storage.fallbackDns,
      );
    }
    _checkPermissionAndRefreshInfo();
  }

  Future<void> _checkPermissionAndRefreshInfo() async {
    setState(() => _isLoadingInfo = true);
    final granted = await _musicService.isNotificationAccessGranted();
    PlaybackInfo? info;
    if (granted) {
      info = await _musicService.getPlaybackInfo();
    }
    if (mounted) {
      setState(() {
        _hasNotificationPermission = granted;
        _playbackInfo = info;
        _isLoadingInfo = false;
      });
    }
  }

  Future<void> _openNotificationSettings() async {
    await _musicService.openNotificationAccessSettings();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已打开系统设置，请在列表中找到【MyYaris 音乐播控监听】并开启授权'),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _togglePlayPause() async {
    final res = await _musicService.togglePlayPause();
    _showActionResult(res['message']?.toString() ?? '播控指令已发送');
    await _refreshInfoQuietly();
  }

  Future<void> _skipToPrevious() async {
    final res = await _musicService.skipToPrevious();
    _showActionResult(res['message']?.toString() ?? '已发送上一曲');
    await _refreshInfoQuietly();
  }

  Future<void> _skipToNext() async {
    final res = await _musicService.skipToNext();
    _showActionResult(res['message']?.toString() ?? '已发送下一曲');
    await _refreshInfoQuietly();
  }

  Future<void> _refreshInfoQuietly() async {
    if (_hasNotificationPermission) {
      final info = await _musicService.getPlaybackInfo();
      if (mounted) {
        setState(() => _playbackInfo = info);
      }
    }
  }

  void _showActionResult(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          backgroundColor: const Color(0xFF222834),
        ),
      );
    }
  }

  void _showCustomActionDialog() async {
    final selected = await showDialog<String>(context: context, builder: (context) => SimpleDialog(
      title: const Text('播放模式'),
      children: [
        for (final mode in const {'list_loop': '喜欢歌单循环', 'shuffle': '喜欢歌单随机', 'intelligence': '网易云心动'}.entries)
          SimpleDialogOption(onPressed: () => Navigator.pop(context, mode.key), child: Text(mode.value)),
      ],
    ));
    if (selected == null || !mounted) return;
    final sync = CarMusicSyncService();
    await sync.requestLocalCommand('set_playback_mode', {'mode': selected});
    if (mounted) _showActionResult(sync.lastCommandNotifier.value);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.poller,
      builder: (context, _) {
        final poller = widget.poller;
        final isRunning = poller.isRunning;
        final statusColor = isRunning ? Colors.blueAccent : Colors.grey;

        return Scaffold(
          backgroundColor: const Color(0xFF121418),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Header Bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.directions_car, color: Colors.blueAccent, size: 22),
                          const SizedBox(width: 8),
                          const Text(
                            'MyYaris 车机助手',
                            style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: statusColor, width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: statusColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  isRunning ? '导航接收中' : '导航未接收',
                                  style: TextStyle(color: statusColor, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // Top Action Buttons (Player & Debug Page)
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          reverse: true,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                          ValueListenableBuilder<MusicSyncMode>(
                            valueListenable: CarMusicSyncService().syncModeNotifier,
                            builder: (context, mode, _) {
                              Color badgeColor;
                              String badgeText;
                              switch (mode) {
                                case MusicSyncMode.websocket:
                                  badgeColor = Colors.greenAccent;
                                  badgeText = '实时播控';
                                  break;
                                case MusicSyncMode.httpPolling:
                                  badgeColor = Colors.amberAccent;
                                  badgeText = '定时播控';
                                  break;
                                case MusicSyncMode.disconnected:
                                  badgeColor = Colors.grey;
                                  badgeText = '播控未连接';
                                  break;
                              }
                              return Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                                decoration: BoxDecoration(
                                  color: badgeColor.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: badgeColor.withValues(alpha: 0.4), width: 1),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      badgeText,
                                      style: TextStyle(color: badgeColor, fontSize: 10, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          ValueListenableBuilder<ObdTelemetry>(
                            valueListenable: CarObdService().telemetryNotifier,
                            builder: (context, tel, _) {
                              final isReady = tel.status == ObdConnectionStatus.ready;
                              final color = isReady ? Colors.tealAccent : Colors.grey;
                              final text = isReady
                                  ? (tel.batterySoc != null
                                      ? 'OBD: ${tel.batterySoc!.toStringAsFixed(0)}%电'
                                      : 'OBD在线')
                                  : 'OBD离线';
                              return Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      text,
                                      style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1B2A22),
                              foregroundColor: Colors.greenAccent,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Colors.greenAccent, width: 1),
                              ),
                            ),
                            icon: const Icon(Icons.electric_car, size: 15, color: Colors.greenAccent),
                            label: const Text(
                              'OBD 混动车况',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (ctx) => const ObdDashboardPage(),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF162E2E),
                              foregroundColor: Colors.tealAccent,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Colors.tealAccent, width: 1),
                              ),
                            ),
                            icon: const Icon(Icons.graphic_eq, size: 15, color: Colors.tealAccent),
                            label: const Text(
                              '播放队列',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (ctx) => const BuiltInPlayerPage(),
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF232A38),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Colors.blueAccent, width: 1),
                              ),
                            ),
                            icon: const Icon(Icons.tune, size: 15, color: Colors.blueAccent),
                            label: const Text(
                              '连接与调试 (后台与导航)',
                              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold),
                            ),
                            onPressed: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (ctx) => ConnectionDebugPage(
                                    storage: widget.storage,
                                    poller: widget.poller,
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Notification Permission / Status Banner
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _hasNotificationPermission
                          ? Colors.blue.withValues(alpha: 0.1)
                          : Colors.amber.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _hasNotificationPermission
                            ? Colors.blueAccent.withValues(alpha: 0.3)
                            : Colors.amberAccent.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _hasNotificationPermission ? Icons.music_note : Icons.warning_amber_rounded,
                          size: 14,
                          color: _hasNotificationPermission ? Colors.blueAccent : Colors.amberAccent,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _hasNotificationPermission
                                ? '网易云播放 · 完整喜欢歌单 · 车机可自主切歌'
                                : '读取播放信息和控制音乐需要通知使用权，请在系统设置中开启授权',
                            style: TextStyle(
                              color: _hasNotificationPermission ? Colors.white70 : Colors.amberAccent,
                              fontSize: 10.5,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: _hasNotificationPermission
                              ? _checkPermissionAndRefreshInfo
                              : _openNotificationSettings,
                          child: Text(
                            _hasNotificationPermission ? '刷新状态' : '去开启授权',
                            style: TextStyle(
                              color: _hasNotificationPermission ? Colors.blueAccent : Colors.orangeAccent,
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Main Body Panels (800x480 Optimized)
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left Panel: Playback Info & Transport Controls
                        Expanded(
                          flex: 3,
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1B1F27),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      '当前播放信息与播控',
                                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.refresh, size: 16, color: Colors.blueAccent),
                                      onPressed: _checkPermissionAndRefreshInfo,
                                      tooltip: '刷新播放信息',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                // Current track display card
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: Colors.black38,
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.white10),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.album, size: 28, color: Colors.blueAccent),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              _playbackInfo?.title.isNotEmpty == true
                                                  ? _playbackInfo!.title
                                                  : (_isLoadingInfo ? '正在读取会话...' : '点播放以使用完整喜欢歌单'),
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 13,
                                                fontWeight: FontWeight.bold,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            Text(
                                              _playbackInfo?.artist.isNotEmpty == true
                                                  ? '${_playbackInfo!.artist} ${_playbackInfo!.album.isNotEmpty ? "• ${_playbackInfo!.album}" : ""}'
                                                  : '歌手: 未知',
                                              style: const TextStyle(color: Colors.white60, fontSize: 10.5),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: (_playbackInfo?.isPlaying ?? false)
                                              ? Colors.green.withValues(alpha: 0.2)
                                              : Colors.grey.withValues(alpha: 0.2),
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(
                                            color: (_playbackInfo?.isPlaying ?? false)
                                                ? Colors.greenAccent
                                                : Colors.grey,
                                          ),
                                        ),
                                        child: Text(
                                          _playbackInfo?.stateName ?? '未连接',
                                          style: TextStyle(
                                            color: (_playbackInfo?.isPlaying ?? false)
                                                ? Colors.greenAccent
                                                : Colors.white70,
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // Transport Controls (Big tactile buttons)
                                Row(
                                  children: [
                                    Expanded(
                                      child: SizedBox(
                                        height: 44,
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.white,
                                            side: const BorderSide(color: Colors.white24),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          ),
                                          onPressed: _hasNotificationPermission ? _skipToPrevious : null,
                                          icon: const Icon(Icons.skip_previous, size: 20),
                                          label: const Text('上一曲', style: TextStyle(fontSize: 12)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      flex: 2,
                                      child: SizedBox(
                                        height: 44,
                                        child: ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.blueAccent.shade700,
                                            foregroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          ),
                                          onPressed: _hasNotificationPermission ? _togglePlayPause : null,
                                          icon: Icon(
                                            (_playbackInfo?.isPlaying ?? false) ? Icons.pause : Icons.play_arrow,
                                            size: 22,
                                          ),
                                          label: Text(
                                            (_playbackInfo?.isPlaying ?? false) ? '暂停' : '播放/暂停',
                                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: SizedBox(
                                        height: 44,
                                        child: OutlinedButton.icon(
                                          style: OutlinedButton.styleFrom(
                                            foregroundColor: Colors.white,
                                            side: const BorderSide(color: Colors.white24),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                          ),
                                          onPressed: _hasNotificationPermission ? _skipToNext : null,
                                          icon: const Icon(Icons.skip_next, size: 20),
                                          label: const Text('下一曲', style: TextStyle(fontSize: 12)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                // Mode Test Button
                                SizedBox(
                                  width: double.infinity,
                                  height: 40,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF262D3D),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        side: const BorderSide(color: Colors.blueAccent, width: 0.8),
                                      ),
                                    ),
                                    onPressed: _showCustomActionDialog,
                                    icon: const Icon(Icons.repeat, size: 18, color: Colors.blueAccent),
                                    label: const Text(
                                      '播放模式',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Right Panel: Music guidance
                        Expanded(
                          flex: 2,
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1D24),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '歌曲与歌单',
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  '请通过手机搜索单曲或选择我喜欢的音乐',
                                  style: TextStyle(color: Colors.white38, fontSize: 9.5),
                                ),
                                const SizedBox(height: 8),
                                // Result feedback container
                                Expanded(
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: SingleChildScrollView(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            '在手机上搜索歌曲，或打开“我喜欢的音乐”选择歌曲，再发送到车机播放。',
                                            style: TextStyle(color: Colors.white70, fontSize: 10.5),
                                          ),
                                          const SizedBox(height: 6),
                                          const Text(
                                            '手机搜索的单曲播放结束后会停止；循环和随机播放使用完整喜欢歌单。',
                                            style: TextStyle(color: Colors.white38, fontSize: 9.5),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Footer info (no sensitive token shown)
                  const Text(
                    'MyYaris v1.0.0 • 车机触控界面 • 连接与授权在“连接与调试”中设置',
                    style: TextStyle(color: Colors.white24, fontSize: 9.5),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
