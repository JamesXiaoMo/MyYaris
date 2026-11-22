import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/obd_telemetry.dart';
import '../services/app_update_service.dart';
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
          '将按账号最高可用音质（母带 / Hi-Res / 无损 FLAC）把完整「我喜欢的音乐」逐首缓存到 SD 卡，以供离线零流量播放。\n\n请确认当前已连接不限量 Wi-Fi（若 Wi-Fi 断开会自动暂停）。',
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

  Future<void> _checkForGithubUpdate() async {
    final updater = AppUpdateService();
    AppUpdateInfo? info;
    String? error;
    bool checking = true;
    bool downloading = false;
    double progress = 0;

    bool started = false;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (!started) {
            started = true;
            updater.checkForUpdate().then((res) {
              if (!ctx.mounted) return;
              setDialogState(() {
                info = res;
                checking = false;
              });
            }).catchError((Object e) {
              if (!ctx.mounted) return;
              setDialogState(() {
                error = '检查更新失败，请确认车机网络可访问 GitHub';
                checking = false;
              });
            });
          }

          return AlertDialog(
            backgroundColor: YarisCarTheme.paper,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text(
              '检查车机端更新',
              style: TextStyle(color: YarisCarTheme.ink, fontSize: 17, fontWeight: FontWeight.w700),
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (checking)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 20),
                      child: Row(
                        children: [
                          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.2)),
                          SizedBox(width: 12),
                          Text('正在检查 GitHub 最新版本…', style: TextStyle(color: YarisCarTheme.muted)),
                        ],
                      ),
                    )
                  else if (error != null)
                    Text(error!, style: const TextStyle(color: YarisCarTheme.red, fontSize: 13.5))
                  else if (info != null && !info!.hasUpdate)
                    Text(
                      '当前已是最新版本（v${info!.currentVersion}）',
                      style: const TextStyle(color: YarisCarTheme.ink, fontSize: 14),
                    )
                  else if (info != null) ...[
                    Text(
                      '发现新版本：v${info!.latestVersion}（当前 v${info!.currentVersion}）',
                      style: const TextStyle(
                        color: YarisCarTheme.ink,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (info!.releaseNotes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 120),
                        child: SingleChildScrollView(
                          child: Text(
                            info!.releaseNotes,
                            style: const TextStyle(color: YarisCarTheme.muted, fontSize: 12.5),
                          ),
                        ),
                      ),
                    ],
                    if (downloading) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: progress > 0 ? progress : null,
                        backgroundColor: YarisCarTheme.neutral,
                        color: YarisCarTheme.blue,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '正在下载安装包 ${(progress * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: YarisCarTheme.muted, fontSize: 12),
                      ),
                    ],
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: downloading ? null : () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
              if (!checking && info != null && info!.hasUpdate && info!.apkUrl != null)
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: YarisCarTheme.blue,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: downloading
                      ? null
                      : () async {
                          setDialogState(() {
                            downloading = true;
                            progress = 0;
                            error = null;
                          });
                          try {
                            final status = await updater.downloadAndInstall(
                              apkUrl: info!.apkUrl!,
                              onProgress: (p) {
                                if (ctx.mounted) setDialogState(() => progress = p);
                              },
                            );
                            if (ctx.mounted) Navigator.pop(ctx);
                            if (mounted && status == 'PERMISSION_REQUIRED') {
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                const SnackBar(content: Text('请先开启「允许安装未知应用」，返回后再次点击安装')),
                              );
                            }
                          } catch (_) {
                            if (ctx.mounted) {
                              setDialogState(() {
                                downloading = false;
                                error = '下载或拉起安装失败，请稍后重试';
                              });
                            }
                          }
                        },
                  child: Text(downloading ? '下载中…' : '下载并安装'),
                ),
            ],
          );
        },
      ),
    );
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
                              icon: Icons.system_update_rounded,
                              title: '检查 GitHub 更新',
                              trailingText: 'v${AppUpdateService.currentVersion}',
                              trailingColor: YarisCarTheme.blue,
                              onTap: _checkForGithubUpdate,
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
  final VoidCallback onTap;

  const _SettingsActionRow({
    required this.icon,
    required this.title,
    required this.trailingText,
    required this.trailingColor,
    required this.onTap,
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
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right_rounded, size: 18, color: YarisCarTheme.muted),
          ],
        ),
      ),
    );
  }
}

class _SettingsSwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsSwitchRow({
    required this.icon,
    required this.title,
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
            child: Text(
              title,
              style: const TextStyle(
                color: YarisCarTheme.ink,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
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
