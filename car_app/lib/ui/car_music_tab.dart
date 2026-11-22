import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../models/music_queue_models.dart';
import '../services/backend_client.dart';
import '../services/built_in_player_service.dart';
import '../services/car_music_queue_controller.dart';
import '../services/car_music_sync_service.dart';
import '../services/storage_service.dart';
import 'yaris_car_theme.dart';

/// Full-featured music playback & queue tab matching the redesigned iOS style.
class CarMusicTab extends StatefulWidget {
  final IStorageService? storage;

  const CarMusicTab({super.key, this.storage});

  @override
  State<CarMusicTab> createState() => _CarMusicTabState();
}

class _CarMusicTabState extends State<CarMusicTab> {
  final BuiltInPlayerService _playerService = BuiltInPlayerService();

  @override
  void initState() {
    super.initState();
    _playerService.init();
  }

  String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds < 0 ? 0 : d.inSeconds;
    final m = (totalSeconds ~/ 60).toString();
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _sendMode(String mode) async {
    await CarMusicSyncService().requestLocalCommand('set_playback_mode', {'mode': mode});
  }

  Future<void> _openGuestDjQrDialog() async {
    final storage = widget.storage;
    if (storage == null || storage.backendUrl.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在设置中配置后端服务连接')),
      );
      return;
    }

    String? qrUrl;
    String? errorMsg;
    bool loading = true;

    Future<void> loadSession(void Function(void Function()) setDialogState, {bool forceNew = false}) async {
      setDialogState(() {
        loading = true;
        errorMsg = null;
      });
      final client = BackendClient(fallbackDns: storage.fallbackDns);
      try {
        final data = await client.createDjSession(
          baseUrl: storage.backendUrl,
          token: storage.carToken,
          deviceId: storage.deviceId,
          forceNew: forceNew,
        );
        if (!mounted) return;
        setDialogState(() {
          qrUrl = data['url']?.toString();
          loading = false;
        });
      } catch (e) {
        if (!mounted) return;
        setDialogState(() {
          errorMsg = '生成点歌二维码失败，请检查网络连接';
          loading = false;
        });
      } finally {
        client.close();
      }
    }

    bool started = false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (!started) {
            started = true;
            Future.microtask(() => loadSession(setDialogState));
          }
          return AlertDialog(
            backgroundColor: YarisCarTheme.paper,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            title: const Row(
              children: [
                Icon(Icons.qr_code_2_rounded, color: YarisCarTheme.blue, size: 22),
                SizedBox(width: 8),
                Text(
                  '副驾 / 后排扫码点歌',
                  style: TextStyle(color: YarisCarTheme.ink, fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            content: SizedBox(
              width: 300,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (loading)
                    const SizedBox(
                      height: 200,
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (errorMsg != null)
                    SizedBox(
                      height: 160,
                      child: Center(
                        child: Text(
                          errorMsg!,
                          style: const TextStyle(color: YarisCarTheme.red, fontSize: 13.5),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else if (qrUrl != null && qrUrl!.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: YarisCarTheme.line),
                      ),
                      child: QrImageView(
                        data: qrUrl!,
                        version: QrVersions.auto,
                        size: 196,
                        backgroundColor: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: loading
                    ? null
                    : () async {
                        final client = BackendClient(fallbackDns: storage.fallbackDns);
                        await client.revokeDjSession(
                          baseUrl: storage.backendUrl,
                          token: storage.carToken,
                          deviceId: storage.deviceId,
                        );
                        client.close();
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            const SnackBar(content: Text('已关闭扫码点歌')),
                          );
                        }
                      },
                child: const Text('关闭点歌', style: TextStyle(color: YarisCarTheme.red)),
              ),
              TextButton(
                onPressed: loading ? null : () => loadSession(setDialogState, forceNew: true),
                child: const Text('刷新二维码'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: YarisCarTheme.blue,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.pop(ctx),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 11,
          child: _buildPlayerCard(),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 9,
          child: _buildQueueCard(),
        ),
      ],
    );
  }

  Widget _buildPlayerCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: YarisCarTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header + Artwork + Track Info
          Expanded(
            flex: 5,
            child: ValueListenableBuilder(
              valueListenable: CarMusicQueueController().currentTrackNotifier,
              builder: (context, _, _) {
                return StreamBuilder<int?>(
                  stream: _playerService.player.currentIndexStream,
                  builder: (context, _) {
                    final track = _playerService.currentTrack;
                    final hasTrack = track.id.isNotEmpty && track.title != '无播放曲目';
                    return Row(
                      children: [
                        const YarisMusicArtwork(size: 108, borderRadius: 22),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ValueListenableBuilder<MusicSyncMode>(
                                valueListenable: CarMusicSyncService().syncModeNotifier,
                                builder: (context, syncMode, _) {
                                  final isOnline = syncMode != MusicSyncMode.disconnected;
                                  return YarisStatusPill(
                                    text: isOnline ? '已连接网易云' : '播控未连接',
                                    color: isOnline ? YarisCarTheme.green : YarisCarTheme.muted,
                                    backgroundColor:
                                        isOnline ? YarisCarTheme.greenBg : YarisCarTheme.neutral,
                                    showDot: true,
                                  );
                                },
                              ),
                              const SizedBox(height: 10),
                              Text(
                                hasTrack ? track.title : '等待播放',
                                style: const TextStyle(
                                  color: YarisCarTheme.ink,
                                  fontSize: 21,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (hasTrack && track.artist.isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Text(
                                  track.artist,
                                  style: const TextStyle(
                                    color: YarisCarTheme.muted,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          ),

          // Progress Slider
          StreamBuilder<Duration>(
            stream: _playerService.player.positionStream,
            builder: (context, posSnap) {
              final pos = posSnap.data ?? Duration.zero;
              final total = _playerService.player.duration ?? Duration.zero;
              final maxMs = total.inMilliseconds > 0 ? total.inMilliseconds.toDouble() : 1.0;
              final curMs = pos.inMilliseconds.toDouble().clamp(0.0, maxMs);

              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                      activeTrackColor: YarisCarTheme.blue,
                      inactiveTrackColor: YarisCarTheme.neutral,
                      thumbColor: YarisCarTheme.blue,
                      overlayColor: YarisCarTheme.periwinkle,
                    ),
                    child: Slider(
                      value: curMs,
                      min: 0.0,
                      max: maxMs,
                      onChanged: total.inMilliseconds > 0
                          ? (v) => _playerService.seek(Duration(milliseconds: v.toInt()))
                          : null,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _formatDuration(pos),
                          style: const TextStyle(color: YarisCarTheme.muted, fontSize: 11.5),
                        ),
                        Text(
                          total.inMilliseconds > 0 ? _formatDuration(total) : '--:--',
                          style: const TextStyle(color: YarisCarTheme.muted, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 8),

          // Transport Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 30,
                color: YarisCarTheme.ink,
                tooltip: '上一曲',
                onPressed: () => CarMusicSyncService().requestLocalCommand('prev'),
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              const SizedBox(width: 18),
              StreamBuilder<PlayerState>(
                stream: _playerService.player.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  return SizedBox(
                    width: 58,
                    height: 58,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                        backgroundColor: YarisCarTheme.blue,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        CarMusicSyncService().requestLocalCommand(playing ? 'pause' : 'resume');
                      },
                      child: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 32,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 18),
              IconButton(
                iconSize: 30,
                color: YarisCarTheme.ink,
                tooltip: '下一曲',
                onPressed: () => CarMusicSyncService().requestLocalCommand('next'),
                icon: const Icon(Icons.skip_next_rounded),
              ),
              const SizedBox(width: 12),
              IconButton(
                iconSize: 24,
                color: YarisCarTheme.muted,
                tooltip: '停止',
                onPressed: () => CarMusicSyncService().requestLocalCommand('stop'),
                icon: const Icon(Icons.stop_rounded),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // 3 Playback Modes
          ValueListenableBuilder<PlaybackMode>(
            valueListenable: CarMusicQueueController().appliedModeNotifier,
            builder: (context, mode, _) {
              return Row(
                children: [
                  Expanded(
                    child: _ModePillButton(
                      label: '喜欢循环',
                      selected: mode == PlaybackMode.listLoop,
                      onTap: () => _sendMode('list_loop'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ModePillButton(
                      label: '喜欢随机',
                      selected: mode == PlaybackMode.shuffle,
                      onTap: () => _sendMode('shuffle'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ModePillButton(
                      label: '网易云心动',
                      selected: mode == PlaybackMode.intelligence,
                      isHeart: true,
                      onTap: () => _sendMode('intelligence'),
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 10),

          // Safe Volume Control
          Row(
            children: [
              const Icon(Icons.volume_down_rounded, size: 18, color: YarisCarTheme.muted),
              const SizedBox(width: 4),
              Text(
                '安全音量 ${(_playerService.currentVolume * 100).toInt()}%',
                style: const TextStyle(
                  color: YarisCarTheme.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.5,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    activeTrackColor: YarisCarTheme.blue,
                    inactiveTrackColor: YarisCarTheme.neutral,
                    thumbColor: YarisCarTheme.blue,
                  ),
                  child: Slider(
                    value: _playerService.currentVolume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) {
                      setState(() {
                        _playerService.setVolume(v);
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildQueueCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: YarisCarTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '当前播放队列',
                style: TextStyle(
                  color: YarisCarTheme.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: YarisCarTheme.periwinkle,
                  foregroundColor: YarisCarTheme.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  minimumSize: const Size(0, 32),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                onPressed: _openGuestDjQrDialog,
                icon: const Icon(Icons.qr_code_2_rounded, size: 16),
                label: const Text(
                  '扫码点歌',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: ValueListenableBuilder(
              valueListenable: CarMusicQueueController().currentTrackNotifier,
              builder: (context, _, _) {
                final tracks = _playerService.tracks;
                final currentIdx = CarMusicQueueController().currentIndex;
                if (tracks.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.queue_music_rounded, size: 36, color: YarisCarTheme.muted),
                          SizedBox(height: 10),
                          Text(
                            '播放队列为空',
                            style: TextStyle(
                              color: YarisCarTheme.ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: tracks.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, i) {
                    final item = tracks[i];
                    final selected = i == currentIdx;
                    return Material(
                      color: selected ? YarisCarTheme.periwinkle : YarisCarTheme.canvas,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => _playerService.selectTrack(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          child: Row(
                            children: [
                              SizedBox(
                                width: 22,
                                child: Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    color: selected ? YarisCarTheme.blue : YarisCarTheme.muted,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.title,
                                      style: TextStyle(
                                        color: selected ? YarisCarTheme.blue : YarisCarTheme.ink,
                                        fontSize: 13.5,
                                        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    if (item.artist.isNotEmpty)
                                      Text(
                                        item.artist,
                                        style: const TextStyle(
                                          color: YarisCarTheme.muted,
                                          fontSize: 11,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                  ],
                                ),
                              ),
                              Icon(
                                selected ? Icons.equalizer_rounded : Icons.play_arrow_rounded,
                                size: 18,
                                color: selected ? YarisCarTheme.blue : YarisCarTheme.muted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ModePillButton extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isHeart;
  final VoidCallback onTap;

  const _ModePillButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.isHeart = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isHeart
        ? (selected ? YarisCarTheme.red : YarisCarTheme.rose)
        : (selected ? YarisCarTheme.periwinkle : YarisCarTheme.neutral);
    final fg = isHeart
        ? (selected ? Colors.white : YarisCarTheme.red)
        : (selected ? YarisCarTheme.blue : YarisCarTheme.ink);

    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isHeart) ...[
                Icon(Icons.favorite_rounded, size: 14, color: fg),
                const SizedBox(width: 4),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
