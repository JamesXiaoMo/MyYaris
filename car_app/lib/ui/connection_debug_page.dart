import 'package:flutter/material.dart';
import '../services/backend_client.dart';
import '../services/car_music_sync_service.dart';
import '../services/storage_service.dart';
import '../services/system_ui_service.dart';
import '../services/task_poller_service.dart';

class ConnectionDebugPage extends StatefulWidget {
  final IStorageService storage;
  final TaskPollerService poller;

  const ConnectionDebugPage({
    super.key,
    required this.storage,
    required this.poller,
  });

  @override
  State<ConnectionDebugPage> createState() => _ConnectionDebugPageState();
}

class _ConnectionDebugPageState extends State<ConnectionDebugPage> {
  late final TextEditingController _urlController;
  late final TextEditingController _deviceIdController;
  late final TextEditingController _tokenController;

  bool _isTestingConnection = false;
  String? _testResultNotice;
  late bool _isFullscreen;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.storage.backendUrl);
    _deviceIdController = TextEditingController(text: widget.storage.deviceId);
    _tokenController = TextEditingController(text: widget.storage.carToken);
    _isFullscreen = widget.storage.isFullscreenEnabled;
  }

  Future<void> _toggleFullscreen(bool value) async {
    setState(() => _isFullscreen = value);
    await widget.storage.setFullscreenEnabled(value);
    await SystemUiService.setFullscreen(value);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _deviceIdController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _saveConfig() async {
    final newUrl = _urlController.text.trim();
    final newDeviceId = _deviceIdController.text.trim();
    final newToken = _tokenController.text.trim();

    await widget.storage.setBackendUrl(newUrl);
    await widget.storage.setDeviceId(newDeviceId);
    await widget.storage.setCarToken(newToken);

    if (newUrl.isNotEmpty) {
      CarMusicSyncService().start(
        baseUrl: newUrl,
        deviceId: newDeviceId,
        token: newToken,
      );
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('配置已保存 (令牌仅在车机本地运行时加密保存，未硬编码至源码)'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTestingConnection = true;
      _testResultNotice = null;
    });

    final client = BackendClient();
    final url = _urlController.text.trim();
    final ok = await client.checkHealth(url);
    client.close();

    if (mounted) {
      setState(() {
        _isTestingConnection = false;
        _testResultNotice = ok
            ? '✅ 成功连接后端 /health 端点'
            : '❌ 连接后端失败，请确认 Tailscale 网络已连接或 HTTPS 域名有效';
      });
    }
  }

  void _showConfigDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1E222B),
              insetPadding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              title: const Row(
                children: [
                  Icon(Icons.settings_ethernet, color: Colors.blueAccent, size: 20),
                  SizedBox(width: 8),
                  Text('车机连接配置', style: TextStyle(color: Colors.white, fontSize: 16)),
                ],
              ),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'HTTPS 后端地址 (R9000P Tailscale):',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                      const SizedBox(height: 2),
                      TextField(
                        controller: _urlController,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        decoration: InputDecoration(
                          hintText: 'https://myyaris.example.com',
                          filled: true,
                          isDense: true,
                          fillColor: Colors.black26,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '设备标识 (Device ID):',
                                  style: TextStyle(color: Colors.white70, fontSize: 11),
                                ),
                                const SizedBox(height: 2),
                                TextField(
                                  controller: _deviceIdController,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                  decoration: InputDecoration(
                                    hintText: 'car_p3pro',
                                    filled: true,
                                    isDense: true,
                                    fillColor: Colors.black26,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            flex: 3,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '车机令牌 (CAR_TOKEN - 运行时保密):',
                                  style: TextStyle(color: Colors.white70, fontSize: 11),
                                ),
                                const SizedBox(height: 2),
                                TextField(
                                  controller: _tokenController,
                                  obscureText: true,
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                  decoration: InputDecoration(
                                    hintText: '输入 CAR_TOKEN',
                                    filled: true,
                                    isDense: true,
                                    fillColor: Colors.black26,
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Colors.white24, height: 20),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  _isFullscreen ? Icons.fullscreen : Icons.fullscreen_exit,
                                  color: Colors.blueAccent,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      '全屏显示 (沉浸模式)',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _isFullscreen
                                          ? '已开启：隐藏系统状态栏，屏幕手势可临时呼出'
                                          : '已关闭：恢复系统标准状态栏显示',
                                      style: const TextStyle(color: Colors.white54, fontSize: 9.5),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            Switch(
                              value: _isFullscreen,
                              activeThumbColor: Colors.blueAccent,
                              onChanged: (val) async {
                                setDialogState(() => _isFullscreen = val);
                                await _toggleFullscreen(val);
                              },
                            ),
                          ],
                        ),
                      ),
                      if (_testResultNotice != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          _testResultNotice!,
                          style: TextStyle(
                            fontSize: 12,
                            color: _testResultNotice!.startsWith('✅')
                                ? Colors.greenAccent
                                : Colors.redAccent,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: _isTestingConnection
                      ? null
                      : () async {
                          await _testConnection();
                          setDialogState(() {});
                        },
                  child: _isTestingConnection
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('测试连通性'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    await _saveConfig();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('保存配置'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.poller,
      builder: (context, _) {
        final poller = widget.poller;
        final isRunning = poller.isRunning;
        final status = poller.status;
        final statusMsg = poller.statusMessage;

        Color statusColor = Colors.grey;
        if (status == PollerStatus.polling) statusColor = Colors.blueAccent;
        if (status == PollerStatus.receivedTask || status == PollerStatus.launchingNavigation) {
          statusColor = Colors.amberAccent;
        }
        if (status == PollerStatus.reconnecting) statusColor = Colors.orangeAccent;
        if (status == PollerStatus.pausedAuthError || status == PollerStatus.error) {
          statusColor = Colors.redAccent;
        }

        return Scaffold(
          backgroundColor: const Color(0xFF121418),
          appBar: AppBar(
            backgroundColor: const Color(0xFF161920),
            elevation: 0,
            titleSpacing: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
              onPressed: () => Navigator.pop(context),
              tooltip: '返回首页',
            ),
            title: Row(
              children: [
                const Text(
                  '连接与调试 (后台与导航)',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
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
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        isRunning ? '轮询运行中' : '已停止',
                        style: TextStyle(color: statusColor, fontSize: 10),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: _isFullscreen ? '退出全屏' : '全屏显示',
                onPressed: () => _toggleFullscreen(!_isFullscreen),
                icon: Icon(
                  _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  color: Colors.white70,
                  size: 20,
                ),
              ),
              IconButton(
                tooltip: '连接参数配置',
                onPressed: _showConfigDialog,
                icon: const Icon(Icons.settings, color: Colors.white70, size: 20),
              ),
              const SizedBox(width: 4),
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: ElevatedButton.icon(
                  onPressed: () {
                    if (isRunning) {
                      poller.stop();
                    } else {
                      poller.start();
                    }
                  },
                  icon: Icon(
                    isRunning ? Icons.stop_circle_outlined : Icons.play_arrow_rounded,
                    size: 16,
                  ),
                  label: Text(isRunning ? '停止轮询' : '启用轮询', style: const TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isRunning ? Colors.red.shade700 : Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  ),
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Status Banner
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B1F27),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 14, color: statusColor),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            statusMsg,
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Split Panels
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left: Live Logs
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
                                const Text(
                                  '实时活动与回执日志 (Monotonic Acks):',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Colors.black38,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: poller.activityLogs.isEmpty
                                        ? const Center(
                                            child: Text(
                                              '暂无活动日志，点击右上角【启用轮询】开始监听',
                                              style: TextStyle(color: Colors.white30, fontSize: 11),
                                            ),
                                          )
                                        : ListView.builder(
                                            itemCount: poller.activityLogs.length,
                                            itemBuilder: (ctx, idx) {
                                              return Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 1.5),
                                                child: Text(
                                                  poller.activityLogs[idx],
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 10,
                                                    fontFamily: 'monospace',
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Right: Recent Tasks
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
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    const Text(
                                      '最近接收任务',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      '已处理: ${widget.storage.processedTaskIds.length}',
                                      style: const TextStyle(color: Colors.white38, fontSize: 10),
                                    ),
                                  ],
                                ),
                                const Divider(color: Colors.white12, height: 10),
                                Expanded(
                                  child: poller.recentTasks.isEmpty
                                      ? const Center(
                                          child: Text(
                                            '尚无任务记录',
                                            style: TextStyle(color: Colors.white30, fontSize: 10),
                                          ),
                                        )
                                      : ListView.builder(
                                          itemCount: poller.recentTasks.length,
                                          itemBuilder: (ctx, idx) {
                                            final t = poller.recentTasks[idx];
                                            return Container(
                                              margin: const EdgeInsets.only(bottom: 5),
                                              padding: const EdgeInsets.all(6),
                                              decoration: BoxDecoration(
                                                color: Colors.black26,
                                                borderRadius: BorderRadius.circular(5),
                                                border: Border.all(
                                                  color: t.status.toLowerCase() == 'failed'
                                                      ? Colors.red.withValues(alpha: 0.3)
                                                      : (t.status.toLowerCase() == 'launch_requested'
                                                          ? Colors.green.withValues(alpha: 0.3)
                                                          : Colors.white10),
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                    children: [
                                                      Expanded(
                                                        child: Text(
                                                          t.title,
                                                          style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 11,
                                                            fontWeight: FontWeight.w600,
                                                          ),
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 4),
                                                      _buildTaskStatusBadge(t.status),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    '${t.latitude.toStringAsFixed(6)}, ${t.longitude.toStringAsFixed(6)} (${t.coordSystem})',
                                                    style: const TextStyle(
                                                      color: Colors.blueAccent,
                                                      fontSize: 9,
                                                      fontFamily: 'monospace',
                                                    ),
                                                  ),
                                                  Text(
                                                    'URI: ${t.toGeoUri()}',
                                                    style: const TextStyle(
                                                      color: Colors.white38,
                                                      fontSize: 8.5,
                                                      fontFamily: 'monospace',
                                                    ),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                  if (t.errorMessage != null && t.errorMessage!.isNotEmpty) ...[
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '失败: ${t.errorMessage}',
                                                      style: TextStyle(
                                                        color: Colors.red.shade300,
                                                        fontSize: 8.5,
                                                      ),
                                                      maxLines: 2,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                ),
                                const Divider(color: Colors.white12, height: 10),
                                // Lifecycle Notice
                                Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                                  ),
                                  child: const Row(
                                    children: [
                                      Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 12),
                                      SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          '开机自启与后台常驻已就绪 (Foreground Service & BootReceiver)，离开此页面不影响任务轮询。',
                                          style: TextStyle(color: Colors.greenAccent, fontSize: 9),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // NAVITIME Notice
                                Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(5),
                                    border: Border.all(color: Colors.amber.withValues(alpha: 0.25)),
                                  ),
                                  child: const Row(
                                    children: [
                                      Icon(Icons.navigation_outlined, color: Colors.amberAccent, size: 12),
                                      SizedBox(width: 5),
                                      Expanded(
                                        child: Text(
                                          '唤起说明：向系统请求打开 CAR NAVITIME 目标坐标。状态为【请求唤起】而非导航已开始。',
                                          style: TextStyle(color: Colors.amberAccent, fontSize: 8.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTaskStatusBadge(String status) {
    Color bg;
    Color text;
    String label;
    switch (status.toLowerCase()) {
      case 'launch_requested':
        bg = Colors.green.withValues(alpha: 0.2);
        text = Colors.greenAccent;
        label = '请求唤起';
        break;
      case 'received':
        bg = Colors.blue.withValues(alpha: 0.2);
        text = Colors.blueAccent;
        label = '已收到';
        break;
      case 'failed':
        bg = Colors.red.withValues(alpha: 0.2);
        text = Colors.redAccent;
        label = '调起失败';
        break;
      case 'queued':
        bg = Colors.orange.withValues(alpha: 0.2);
        text = Colors.orangeAccent;
        label = '待处理';
        break;
      default:
        bg = Colors.grey.withValues(alpha: 0.2);
        text = Colors.grey;
        label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: text.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(color: text, fontSize: 8.5, fontWeight: FontWeight.bold),
      ),
    );
  }
}
