import 'package:flutter/material.dart';
import '../services/music_service.dart';
import '../services/storage_service.dart';
import '../services/task_poller_service.dart';
import 'connection_debug_page.dart';

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
  String? _lastRouteResult;

  @override
  void initState() {
    super.initState();
    // Maintain poller running state across navigation
    if (widget.storage.isPollingEnabled && !widget.poller.isRunning) {
      widget.poller.start();
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
    setState(() => _isLoadingInfo = true);
    final info = await _musicService.getPlaybackInfo();
    if (mounted) {
      setState(() {
        _isLoadingInfo = false;
        _playbackInfo = info;
      });
    }

    if (!mounted) return;

    if (!info.hasPermission) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E222B),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 20),
              SizedBox(width: 8),
              Text('缺少通知使用权', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: const Text(
            '读取真实 CustomActions 必须具备【通知使用权】。\n请由用户在车机系统设置中开启。',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _openNotificationSettings();
              },
              child: const Text('前往设置授权'),
            ),
          ],
        ),
      );
      return;
    }

    final actions = info.customActions;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222B),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        title: const Row(
          children: [
            Icon(Icons.repeat, color: Colors.blueAccent, size: 20),
            SizedBox(width: 8),
            Text('播放模式与 CustomAction 实测', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 540,
          height: 310,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '底层 MediaSession 真实数据 • Actions 掩码: ${info.actionsMask} (标准位含PLAY/PAUSE/PREV/NEXT/SEEK_TO/PLAY_PAUSE)\n'
                        '模式读取状态: repeatMode=${info.repeatMode == -1 ? "未暴露(-1)" : info.repeatMode} | shuffleMode=${info.shuffleMode == -1 ? "未暴露(-1)" : info.shuffleMode}',
                        style: const TextStyle(color: Colors.white70, fontSize: 10),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '检测到的 CustomAction 列表 (${actions.length}项，直接呈现底层真实 action 标识):',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              if (actions.isEmpty)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.red.withValues(alpha: 0.3)),
                  ),
                  child: const Text(
                    '当前活跃会话未发现 CustomAction。\n可能原因：网易云音乐尚未在后台运行或已被系统休眠。',
                    style: TextStyle(color: Colors.redAccent, fontSize: 11),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: actions.length,
                    itemBuilder: (c, i) {
                      final a = actions[i];
                      final isPlayMode = a.name.contains('播放模式') || a.action.contains('MODE');
                      return Container(
                        margin: const EdgeInsets.only(bottom: 5),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: isPlayMode ? Colors.blue.withValues(alpha: 0.15) : Colors.black38,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isPlayMode ? Colors.blueAccent : Colors.white12,
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '显示名: ${a.name}',
                                        style: TextStyle(
                                          color: isPlayMode ? Colors.lightBlueAccent : Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                      if (isPlayMode) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.blueAccent,
                                            borderRadius: BorderRadius.circular(3),
                                          ),
                                          child: const Text('模式动作', style: TextStyle(color: Colors.white, fontSize: 8.5)),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    '真实 Action ID: ${a.action.isEmpty ? "(空字符)" : a.action}',
                                    style: const TextStyle(color: Colors.greenAccent, fontSize: 10, fontFamily: 'monospace'),
                                  ),
                                  if (a.extras.isNotEmpty)
                                    Text(
                                      'Extras 键值: ${a.extras}',
                                      style: const TextStyle(color: Colors.white54, fontSize: 9),
                                    ),
                                ],
                              ),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: isPlayMode ? Colors.blueAccent : Colors.white12,
                              ),
                              onPressed: a.action.isEmpty
                                  ? null
                                  : () async {
                                      Navigator.pop(ctx);
                                      final res = await _musicService.sendCustomAction(a.action, a.extras);
                                      _showActionResult(res['message']?.toString() ?? '动作已发送');
                                      await _refreshInfoQuietly();
                                    },
                              child: const Text('测试此动作', style: TextStyle(fontSize: 10)),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _showOpenSongDialog() {
    final controller = TextEditingController(text: '1901371647');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222B),
        title: const Row(
          children: [
            Icon(Icons.music_note, color: Colors.blueAccent, size: 20),
            SizedBox(width: 8),
            Text('打开指定歌曲页面 (Deep Link)', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '输入歌曲 ID (例如 1901371647 漠河舞厅) 或完整链接:',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  '协议说明：使用官方 orpheus://song/{id}。系统 Intent 仅定位详情页，绝不编造未经证实的 autoPlay 参数，是否起播由网易云自行处理。',
                  style: TextStyle(color: Colors.amberAccent, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final text = controller.text.trim();
              Navigator.pop(ctx);
              final res = await _musicService.openSongPage(text);
              final msg = res['message']?.toString() ?? '打开请求已发送';
              setState(() => _lastRouteResult = msg);
              _showActionResult(msg);
            },
            child: const Text('发起打开页面'),
          ),
        ],
      ),
    );
  }

  void _showOpenPlaylistDialog() {
    final controller = TextEditingController(text: '3778678');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222B),
        title: const Row(
          children: [
            Icon(Icons.queue_music, color: Colors.blueAccent, size: 20),
            SizedBox(width: 8),
            Text('打开指定歌单页面 (Deep Link)', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '输入歌单 ID (例如 3778678 热歌榜) 或完整链接:',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.black26,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  '协议说明：使用官方 orpheus://playlist/{id}。系统 Intent 仅定位详情页，未见公开“全部播放”参数，不假装已全部播放。',
                  style: TextStyle(color: Colors.amberAccent, fontSize: 10),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () async {
              final text = controller.text.trim();
              Navigator.pop(ctx);
              final res = await _musicService.openPlaylistPage(text);
              final msg = res['message']?.toString() ?? '打开请求已发送';
              setState(() => _lastRouteResult = msg);
              _showActionResult(msg);
            },
            child: const Text('发起打开页面'),
          ),
        ],
      ),
    );
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
                                  isRunning ? '导航轮询中' : '未启用接收',
                                  style: TextStyle(color: statusColor, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      // Prominent Secondary Page Entry Button
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF232A38),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: const BorderSide(color: Colors.blueAccent, width: 1),
                          ),
                        ),
                        icon: const Icon(Icons.tune, size: 16, color: Colors.blueAccent),
                        label: const Text(
                          '连接与调试 (后台与导航)',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
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
                                ? '网易云音乐本地测试区（大触控按键，已获通知使用权可读写播控）'
                                : '读取播放信息与播控需【通知使用权】（系统安全项），请在系统设置中开启授权',
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
                                      tooltip: '刷新会话信息',
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
                                                  : (_isLoadingInfo ? '正在读取会话...' : '未检测到曲目 (请打开网易云)'),
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
                                      '播放模式测试 (读取真实 CustomAction 与模式)',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Right Panel: Deep Link Testing
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
                                  '指定页面路由测试 (Deep Link)',
                                  style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  '仅通过系统 Intent 请求打开，不编造自动起播参数',
                                  style: TextStyle(color: Colors.white38, fontSize: 9.5),
                                ),
                                const SizedBox(height: 8),
                                // Two Large Buttons
                                SizedBox(
                                  width: double.infinity,
                                  height: 44,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF252B3A),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        side: const BorderSide(color: Colors.white24),
                                      ),
                                    ),
                                    onPressed: _showOpenSongDialog,
                                    icon: const Icon(Icons.music_note, color: Colors.blueAccent, size: 18),
                                    label: const Text('指定歌曲页面', style: TextStyle(fontSize: 12)),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  height: 44,
                                  child: ElevatedButton.icon(
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF252B3A),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(8),
                                        side: const BorderSide(color: Colors.white24),
                                      ),
                                    ),
                                    onPressed: _showOpenPlaylistDialog,
                                    icon: const Icon(Icons.queue_music, color: Colors.blueAccent, size: 18),
                                    label: const Text('指定歌单页面', style: TextStyle(fontSize: 12)),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                // Result feedback container
                                Expanded(
                                  child: Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.black26,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: SingleChildScrollView(
                                      child: Text(
                                        _lastRouteResult ?? '点击上方按钮输入歌曲或歌单 ID/链接进行打开测试。',
                                        style: const TextStyle(color: Colors.white70, fontSize: 10),
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
                    'MyYaris v1.0.0 • 800x480 车机触控优化 • 敏感令牌仅在二级页处理 • 后台长轮询持续运行',
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
