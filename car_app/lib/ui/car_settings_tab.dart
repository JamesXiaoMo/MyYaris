import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/obd_telemetry.dart';
import '../services/backend_client.dart';
import '../services/car_music_sync_service.dart';
import '../services/car_obd_service.dart';
import '../services/music_cache_service.dart';
import '../services/music_service.dart';
import '../services/storage_service.dart';
import '../services/system_ui_service.dart';
import '../services/task_poller_service.dart';
import '../services/trip_tracker_service.dart';
import 'yaris_car_theme.dart';

/// Clean user-facing settings tab (no debug logs, no raw ack/URI dump).
class CarSettingsTab extends StatefulWidget {
  final IStorageService storage;
  final TaskPollerService poller;
  final VoidCallback onOpenObdTab;

  const CarSettingsTab({
    super.key,
    required this.storage,
    required this.poller,
    required this.onOpenObdTab,
  });

  @override
  State<CarSettingsTab> createState() => _CarSettingsTabState();
}

class _CarSettingsTabState extends State<CarSettingsTab> {
  final MusicService _musicService = MusicService();
  late bool _isFullscreen;
  bool _hasNotificationPermission = false;

  @override
  void initState() {
    super.initState();
    _isFullscreen = widget.storage.isFullscreenEnabled;
    _refreshNotificationPermission();
    MusicCacheService().init();
  }

  Future<void> _refreshNotificationPermission() async {
    final granted = await _musicService.isNotificationAccessGranted();
    if (mounted) {
      setState(() => _hasNotificationPermission = granted);
    }
  }

  Future<void> _toggleFullscreen(bool value) async {
    setState(() => _isFullscreen = value);
    await widget.storage.setFullscreenEnabled(value);
    await SystemUiService.setFullscreen(value);
  }

  Future<void> _openNotificationSettings() async {
    await _musicService.openNotificationAccessSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('请在系统设置中开启「MyYaris 音乐播控监听」授权')),
    );
  }

  Future<void> _confirmAndStartBatchCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YarisCarTheme.paper,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '批量缓存我喜欢的音乐',
          style: TextStyle(color: YarisCarTheme.ink, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '将把完整「我喜欢的音乐」逐首缓存到 SD 卡以供离线零流量播放。\n\n请确认当前已连接不限量 Wi-Fi（若 Wi-Fi 断开会自动暂停）。',
          style: TextStyle(color: YarisCarTheme.muted, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: YarisCarTheme.blue,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认在 Wi-Fi 下开始'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    MusicCacheService().startBatchCacheFavorites(
      baseUrl: widget.storage.backendUrl,
      token: widget.storage.carToken,
      deviceId: widget.storage.deviceId,
      fallbackDns: widget.storage.fallbackDns,
    );
  }

  Future<void> _confirmAndClearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YarisCarTheme.paper,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '清空本地音乐缓存',
          style: TextStyle(color: YarisCarTheme.ink, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        content: const Text(
          '确定清空已缓存到 SD 卡的离线音频吗？不会影响你的网易云喜欢歌单。',
          style: TextStyle(color: YarisCarTheme.muted, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: YarisCarTheme.red,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await MusicCacheService().clearAllCache();
  }

  String _formatCacheBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(2)} GB';
    return '${mb.toStringAsFixed(1)} MB';
  }

  void _showBackendConfigDialog() {
    final urlCtrl = TextEditingController(text: widget.storage.backendUrl);
    final deviceCtrl = TextEditingController(text: widget.storage.deviceId);
    final tokenCtrl = TextEditingController(text: widget.storage.carToken);
    final dnsMap = widget.storage.fallbackDns;
    final dnsCtrl = TextEditingController(
      text: dnsMap.entries.map((e) => '${e.key}=${e.value}').join(', '),
    );
    bool isTesting = false;
    String? testNotice;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> save() async {
            final newUrl = urlCtrl.text.trim();
            final newDeviceId = deviceCtrl.text.trim();
            final newToken = tokenCtrl.text.trim();
            final rawDns = dnsCtrl.text.trim();
            final newDns = <String, String>{};

            if (rawDns.isNotEmpty) {
              if (rawDns.startsWith('{') && rawDns.endsWith('}')) {
                try {
                  final decoded = json.decode(rawDns);
                  if (decoded is Map) {
                    for (final entry in decoded.entries) {
                      newDns[entry.key.toString().trim()] = entry.value.toString().trim();
                    }
                  }
                } catch (_) {}
              } else {
                for (final pair in rawDns.split(RegExp(r'[,;\n]'))) {
                  final parts = pair.split(RegExp(r'[:=]'));
                  if (parts.length == 2 &&
                      parts[0].trim().isNotEmpty &&
                      parts[1].trim().isNotEmpty) {
                    newDns[parts[0].trim()] = parts[1].trim();
                  }
                }
              }
            }

            await widget.storage.setBackendUrl(newUrl);
            await widget.storage.setDeviceId(newDeviceId);
            await widget.storage.setCarToken(newToken);
            await widget.storage.setFallbackDns(newDns);

            if (newUrl.isNotEmpty) {
              CarMusicSyncService().start(
                baseUrl: newUrl,
                deviceId: newDeviceId,
                token: newToken,
                fallbackDns: newDns,
              );
              TripTrackerService().start(
                baseUrl: newUrl,
                deviceId: newDeviceId,
                token: newToken,
                fallbackDns: newDns,
              );
            }
          }

          return AlertDialog(
            backgroundColor: YarisCarTheme.paper,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text(
              '后端服务连接',
              style: TextStyle(color: YarisCarTheme.ink, fontSize: 17, fontWeight: FontWeight.w700),
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('服务器地址（HTTPS）',
                        style: TextStyle(color: YarisCarTheme.muted, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: urlCtrl,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(hintText: 'https://backend.example.com'),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('设备标识',
                                  style: TextStyle(color: YarisCarTheme.muted, fontSize: 12)),
                              const SizedBox(height: 6),
                              TextField(
                                controller: deviceCtrl,
                                decoration: const InputDecoration(hintText: 'car_p3pro'),
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
                              const Text('访问令牌',
                                  style: TextStyle(color: YarisCarTheme.muted, fontSize: 12)),
                              const SizedBox(height: 6),
                              TextField(
                                controller: tokenCtrl,
                                obscureText: true,
                                decoration: const InputDecoration(hintText: '输入车机令牌'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('备用地址映射（可选）',
                        style: TextStyle(color: YarisCarTheme.muted, fontSize: 12)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: dnsCtrl,
                      decoration: const InputDecoration(hintText: 'host=ip'),
                    ),
                    if (testNotice != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        testNotice!,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: testNotice!.contains('成功')
                              ? YarisCarTheme.green
                              : YarisCarTheme.red,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: isTesting
                    ? null
                    : () async {
                        setDialogState(() {
                          isTesting = true;
                          testNotice = null;
                        });
                        final client = BackendClient(fallbackDns: widget.storage.fallbackDns);
                        final ok = await client.checkHealth(urlCtrl.text.trim());
                        client.close();
                        if (ctx.mounted) {
                          setDialogState(() {
                            isTesting = false;
                            testNotice = ok ? '连接测试成功' : '连接失败，请检查网络或服务器地址';
                          });
                        }
                      },
                child: Text(isTesting ? '测试中…' : '测试连接'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: YarisCarTheme.blue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  final navigator = Navigator.of(ctx);
                  await save();
                  if (ctx.mounted) navigator.pop();
                  if (mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('连接配置已保存')),
                    );
                    setState(() {});
                  }
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    ).whenComplete(() {
      urlCtrl.dispose();
      deviceCtrl.dispose();
      tokenCtrl.dispose();
      dnsCtrl.dispose();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.poller,
      builder: (context, _) {
        final pollerRunning = widget.poller.isRunning;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '设置',
              style: TextStyle(
                color: YarisCarTheme.ink,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Left Column: Connection & Receive
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 4, bottom: 8),
                            child: Text(
                              '连接与接收',
                              style: TextStyle(
                                color: YarisCarTheme.muted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Container(
                            decoration: YarisCarTheme.cardDecoration(),
                            child: Column(
                              children: [
                                ValueListenableBuilder<bool>(
                                  valueListenable: CarMusicSyncService().isHealthyNotifier,
                                  builder: (context, connected, _) {
                                    return _SettingsActionRow(
                                      icon: Icons.cloud_done_rounded,
                                      title: '后端服务连接',
                                      trailingText: connected ? '已连接' : '未连接',
                                      trailingColor:
                                          connected ? YarisCarTheme.green : YarisCarTheme.muted,
                                      onTap: _showBackendConfigDialog,
                                    );
                                  },
                                ),
                                const Divider(height: 1, color: YarisCarTheme.line),
                                _SettingsSwitchRow(
                                  icon: Icons.navigation_rounded,
                                  title: '接收手机导航',
                                  subtitle: pollerRunning ? '收到目的地后自动唤起 NAVITIME' : '已暂停接收',
                                  value: pollerRunning,
                                  onChanged: (v) {
                                    if (v) {
                                      widget.poller.start();
                                    } else {
                                      widget.poller.stop();
                                    }
                                  },
                                ),
                                const Divider(height: 1, color: YarisCarTheme.line),
                                ValueListenableBuilder<bool>(
                                  valueListenable: TripTrackerService().isRunningNotifier,
                                  builder: (context, tracking, _) {
                                    return _SettingsSwitchRow(
                                      icon: Icons.route_rounded,
                                      title: '行程位置记录',
                                      subtitle: tracking ? '每 10 秒自动上传位置' : '已暂停记录',
                                      value: tracking,
                                      onChanged: (v) {
                                        if (v) {
                                          TripTrackerService().start(
                                            baseUrl: widget.storage.backendUrl,
                                            deviceId: widget.storage.deviceId,
                                            token: widget.storage.carToken,
                                            fallbackDns: widget.storage.fallbackDns,
                                          );
                                        } else {
                                          TripTrackerService().stop();
                                        }
                                      },
                                    );
                                  },
                                ),
                                const Divider(height: 1, color: YarisCarTheme.line),
                                ValueListenableBuilder<ObdTelemetry>(
                                  valueListenable: CarObdService().telemetryNotifier,
                                  builder: (context, tel, _) {
                                    final ready = tel.status == ObdConnectionStatus.ready;
                                    return _SettingsActionRow(
                                      icon: Icons.bluetooth_rounded,
                                      title: '蓝牙 OBD 设备',
                                      trailingText: ready
                                          ? (tel.connectedDeviceName ?? '已连接')
                                          : '未连接',
                                      trailingColor:
                                          ready ? YarisCarTheme.green : YarisCarTheme.muted,
                                      onTap: widget.onOpenObdTab,
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  // Right Column: Display & About
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 4, bottom: 8),
                            child: Text(
                              '显示与权限',
                              style: TextStyle(
                                color: YarisCarTheme.muted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Container(
                            decoration: YarisCarTheme.cardDecoration(),
                            child: Column(
                              children: [
                                _SettingsSwitchRow(
                                  icon: Icons.fullscreen_rounded,
                                  title: '全屏沉浸显示',
                                  subtitle: _isFullscreen ? '隐藏系统状态栏' : '显示系统状态栏',
                                  value: _isFullscreen,
                                  onChanged: _toggleFullscreen,
                                ),
                                const Divider(height: 1, color: YarisCarTheme.line),
                                _SettingsActionRow(
                                  icon: Icons.music_note_rounded,
                                  title: '音乐播控授权',
                                  trailingText: _hasNotificationPermission ? '已开启' : '去开启',
                                  trailingColor: _hasNotificationPermission
                                      ? YarisCarTheme.green
                                      : YarisCarTheme.blue,
                                  onTap: _openNotificationSettings,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Padding(
                            padding: EdgeInsets.only(left: 4, bottom: 8),
                            child: Text(
                              '离线音乐缓存',
                              style: TextStyle(
                                color: YarisCarTheme.muted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Container(
                            decoration: YarisCarTheme.cardDecoration(),
                            child: Column(
                              children: [
                                ValueListenableBuilder<bool>(
                                  valueListenable: MusicCacheService().cacheOnPlayNotifier,
                                  builder: (context, enabled, _) {
                                    return _SettingsSwitchRow(
                                      icon: Icons.sd_storage_rounded,
                                      title: '边听边存到 SD 卡',
                                      subtitle: enabled ? '播过的歌自动缓存，下次零流量秒播' : '已关闭自动缓存',
                                      value: enabled,
                                      onChanged: (v) => MusicCacheService().setCacheOnPlay(v),
                                    );
                                  },
                                ),
                                const Divider(height: 1, color: YarisCarTheme.line),
                                ValueListenableBuilder<BatchCacheProgress>(
                                  valueListenable: MusicCacheService().batchProgressNotifier,
                                  builder: (context, prog, _) {
                                    final isRunning = prog.state == BatchCacheState.running;
                                    return Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.download_for_offline_rounded,
                                                  size: 20, color: YarisCarTheme.blue),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: ValueListenableBuilder<int>(
                                                  valueListenable:
                                                      MusicCacheService().cachedCountNotifier,
                                                  builder: (context, count, _) {
                                                    return ValueListenableBuilder<int>(
                                                      valueListenable:
                                                          MusicCacheService().cachedBytesNotifier,
                                                      builder: (context, bytes, _) {
                                                        return Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment.start,
                                                          children: [
                                                            const Text(
                                                              'Wi-Fi 批量缓存喜欢歌单',
                                                              style: TextStyle(
                                                                color: YarisCarTheme.ink,
                                                                fontSize: 14,
                                                                fontWeight: FontWeight.w600,
                                                              ),
                                                            ),
                                                            Text(
                                                              '${MusicCacheService().storageSummaryNotifier.value} · 已存 $count 首 (${_formatCacheBytes(bytes)})',
                                                              style: const TextStyle(
                                                                color: YarisCarTheme.muted,
                                                                fontSize: 11,
                                                              ),
                                                            ),
                                                          ],
                                                        );
                                                      },
                                                    );
                                                  },
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              if (isRunning)
                                                OutlinedButton(
                                                  onPressed: () => MusicCacheService().pauseBatch(),
                                                  child: const Text('暂停'),
                                                )
                                              else
                                                FilledButton(
                                                  style: FilledButton.styleFrom(
                                                    backgroundColor: YarisCarTheme.blue,
                                                    foregroundColor: Colors.white,
                                                    padding: const EdgeInsets.symmetric(
                                                        horizontal: 12, vertical: 8),
                                                  ),
                                                  onPressed: _confirmAndStartBatchCache,
                                                  child: const Text('开始缓存',
                                                      style: TextStyle(fontSize: 12.5)),
                                                ),
                                            ],
                                          ),
                                          if (prog.message.isNotEmpty) ...[
                                            const SizedBox(height: 8),
                                            Text(
                                              prog.message,
                                              style: TextStyle(
                                                color: prog.state == BatchCacheState.error
                                                    ? YarisCarTheme.red
                                                    : YarisCarTheme.muted,
                                                fontSize: 11.5,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                          if (isRunning && prog.total > 0) ...[
                                            const SizedBox(height: 6),
                                            LinearProgressIndicator(
                                              value: (prog.done / prog.total).clamp(0.0, 1.0),
                                              backgroundColor: YarisCarTheme.neutral,
                                              color: YarisCarTheme.blue,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ],
                                        ],
                                      ),
                                    );
                                  },
                                ),
                                const Divider(height: 1, color: YarisCarTheme.line),
                                _SettingsActionRow(
                                  icon: Icons.delete_sweep_rounded,
                                  title: '清空本地音乐缓存',
                                  trailingText: '释放空间',
                                  trailingColor: YarisCarTheme.red,
                                  onTap: _confirmAndClearCache,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          const Padding(
                            padding: EdgeInsets.only(left: 4, bottom: 8),
                            child: Text(
                              '关于',
                              style: TextStyle(
                                color: YarisCarTheme.muted,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Container(
                            decoration: YarisCarTheme.cardDecoration(),
                            child: _SettingsActionRow(
                              icon: Icons.info_outline_rounded,
                              title: '关于 MyYaris 车机端',
                              trailingText: 'v1.0.0',
                              trailingColor: YarisCarTheme.muted,
                              showChevron: false,
                              onTap: () {},
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
        );
      },
    );
  }
}

class _SettingsActionRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String trailingText;
  final Color trailingColor;
  final bool showChevron;
  final VoidCallback onTap;

  const _SettingsActionRow({
    required this.icon,
    required this.title,
    required this.trailingText,
    required this.trailingColor,
    required this.onTap,
    this.showChevron = true,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: YarisCarTheme.blue),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: YarisCarTheme.ink,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              trailingText,
              style: TextStyle(
                color: trailingColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (showChevron) ...[
              const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, size: 18, color: YarisCarTheme.muted),
            ],
          ],
        ),
      ),
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: YarisCarTheme.blue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: YarisCarTheme.ink,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: YarisCarTheme.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeTrackColor: YarisCarTheme.blue,
            activeThumbColor: Colors.white,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
