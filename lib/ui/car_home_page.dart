import 'package:flutter/material.dart';
import '../services/backend_client.dart';
import '../services/storage_service.dart';
import '../services/task_poller_service.dart';

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
  late final TextEditingController _urlController;
  late final TextEditingController _deviceIdController;
  late final TextEditingController _tokenController;

  bool _isTestingConnection = false;
  String? _testResultNotice;

  @override
  void initState() {
    super.initState();
    _urlController = TextEditingController(text: widget.storage.backendUrl);
    _deviceIdController = TextEditingController(text: widget.storage.deviceId);
    _tokenController = TextEditingController(text: widget.storage.carToken);

    // If storage says polling was enabled, resume
    if (widget.storage.isPollingEnabled) {
      widget.poller.start();
    }
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
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Top Navigation Bar
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.directions_car, color: Colors.blueAccent, size: 24),
                          const SizedBox(width: 8),
                          const Text(
                            'MyYaris 车机助手',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 12),
                          // Status Badge
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: statusColor, width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: statusColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isRunning ? '轮询接收中' : '未启用接收',
                                  style: TextStyle(color: statusColor, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Row(
                        children: [
                          IconButton(
                            tooltip: '设置后端与令牌',
                            onPressed: _showConfigDialog,
                            icon: const Icon(Icons.settings, color: Colors.white70, size: 20),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () {
                              if (isRunning) {
                                poller.stop();
                              } else {
                                poller.start();
                              }
                            },
                            icon: Icon(
                              isRunning ? Icons.stop_circle_outlined : Icons.play_arrow_rounded,
                              size: 18,
                            ),
                            label: Text(isRunning ? '停止接收' : '启用长轮询接收'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: isRunning ? Colors.red.shade700 : Colors.green.shade700,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Current Status Banner
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B1F27),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, size: 16, color: statusColor),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            statusMsg,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Main Split Panels
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Left Panel: Recent Task Card & Live Logs
                        Expanded(
                          flex: 3,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1B1F27),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '实时活动与回执日志 (Monotonic Acks):',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.black38,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.white10),
                                    ),
                                    child: poller.activityLogs.isEmpty
                                        ? const Center(
                                            child: Text(
                                              '暂无活动日志，点击右上角【启用长轮询接收】开始监听',
                                              style: TextStyle(color: Colors.white30, fontSize: 11),
                                            ),
                                          )
                                        : ListView.builder(
                                            reverse: false,
                                            itemCount: poller.activityLogs.length,
                                            itemBuilder: (ctx, idx) {
                                              return Padding(
                                                padding: const EdgeInsets.symmetric(vertical: 2.0),
                                                child: Text(
                                                  poller.activityLogs[idx],
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 11,
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
                        const SizedBox(width: 12),
                        // Right Panel: Recent Tasks & Lifecycle Notice
                        Expanded(
                          flex: 2,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1D24),
                              borderRadius: BorderRadius.circular(12),
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
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      '已处理: ${widget.storage.processedTaskIds.length}',
                                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                                    ),
                                  ],
                                ),
                                const Divider(color: Colors.white12, height: 14),
                                Expanded(
                                  child: poller.recentTasks.isEmpty
                                      ? const Center(
                                          child: Text(
                                            '尚无任务记录',
                                            style: TextStyle(color: Colors.white30, fontSize: 11),
                                          ),
                                        )
                                      : ListView.builder(
                                          itemCount: poller.recentTasks.length,
                                          itemBuilder: (ctx, idx) {
                                            final t = poller.recentTasks[idx];
                                            return Container(
                                              margin: const EdgeInsets.only(bottom: 6),
                                              padding: const EdgeInsets.all(8),
                                              decoration: BoxDecoration(
                                                color: Colors.black26,
                                                borderRadius: BorderRadius.circular(6),
                                                border: Border.all(color: Colors.white10),
                                              ),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    t.title,
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 12,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  Text(
                                                    '${t.latitude}, ${t.longitude} (${t.coordSystem})',
                                                    style: const TextStyle(
                                                      color: Colors.blueAccent,
                                                      fontSize: 10,
                                                      fontFamily: 'monospace',
                                                    ),
                                                  ),
                                                  Text(
                                                    'URI: ${t.toGeoUri()}',
                                                    style: const TextStyle(
                                                      color: Colors.white38,
                                                      fontSize: 9,
                                                      fontFamily: 'monospace',
                                                    ),
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                ),
                                const Divider(color: Colors.white12, height: 14),
                                // Lifecycle Notice
                                Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: Colors.amber.withValues(alpha: 0.2)),
                                  ),
                                  child: const Text(
                                    '注：本轮以应用前台运行期间链路验证为主。跨 NAVITIME 后台持续驻留接收需车载系统特权保活，当前不作为后台常驻守护。',
                                    style: TextStyle(color: Colors.amberAccent, fontSize: 10),
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
}
