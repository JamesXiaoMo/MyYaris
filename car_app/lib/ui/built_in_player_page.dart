import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../services/built_in_player_service.dart';
import '../services/car_music_sync_service.dart';

class BuiltInPlayerPage extends StatefulWidget {
  const BuiltInPlayerPage({super.key});

  @override
  State<BuiltInPlayerPage> createState() => _BuiltInPlayerPageState();
}

class _BuiltInPlayerPageState extends State<BuiltInPlayerPage> {
  final BuiltInPlayerService _service = BuiltInPlayerService();
  bool _isLoading = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _initService();
  }

  Future<void> _initService() async {
    try {
      await _service.init();
      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _initError = e.toString();
        });
      }
    }
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF181C24),
        elevation: 0,
        toolbarHeight: 48,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Row(
          children: [
            Icon(Icons.graphic_eq, color: Colors.tealAccent, size: 20),
            SizedBox(width: 8),
            Text(
              'MyYaris 内置音频播放器验证 (PoC)',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<MusicSyncMode>(
            valueListenable: CarMusicSyncService().syncModeNotifier,
            builder: (context, mode, _) {
              Color badgeColor;
              String badgeText;
              switch (mode) {
                case MusicSyncMode.websocket:
                  badgeColor = Colors.greenAccent;
                  badgeText = 'WS播控';
                  break;
                case MusicSyncMode.httpPolling:
                  badgeColor = Colors.amberAccent;
                  badgeText = 'HTTP轮询';
                  break;
                case MusicSyncMode.disconnected:
                  badgeColor = Colors.grey;
                  badgeText = '播控未连';
                  break;
              }
              return Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: badgeColor.withValues(alpha: 0.5), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 5),
                    Text(badgeText, style: TextStyle(color: badgeColor, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            },
          ),
          StreamBuilder<PlayerState>(
            stream: _service.player.playerStateStream,
            builder: (context, snapshot) {
              final state = snapshot.data;
              final playing = state?.playing ?? false;
              final pState = state?.processingState ?? ProcessingState.idle;

              String stateText = '空闲';
              Color stateColor = Colors.grey;

              if (pState == ProcessingState.buffering || pState == ProcessingState.loading) {
                stateText = '加载中';
                stateColor = Colors.amberAccent;
              } else if (playing) {
                stateText = '播放中';
                stateColor = Colors.greenAccent;
              } else if (pState == ProcessingState.completed) {
                stateText = '已播完';
                stateColor = Colors.blueAccent;
              } else {
                stateText = '已暂停';
                stateColor = Colors.orangeAccent;
              }

              return Container(
                margin: const EdgeInsets.only(right: 14),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: stateColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: stateColor.withValues(alpha: 0.5), width: 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(stateText, style: TextStyle(color: stateColor, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.tealAccent))
          : _initError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      '初始化错误: $_initError\n请检查音频资源配置',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(10.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Left Card: Player Controls & Live Waveform (Width ~430)
                      Expanded(
                        flex: 11,
                        child: _buildControlsCard(),
                      ),
                      const SizedBox(width: 10),
                      // Right Card: Track Playlist & Test Environment (Width ~340)
                      Expanded(
                        flex: 9,
                        child: _buildPlaylistCard(),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _buildControlsCard() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF181C24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Current Track Banner (supports both local WAV and remote stream)
          StreamBuilder<int?>(
            stream: _service.player.currentIndexStream,
            builder: (context, snapshot) {
              final currentTrack = _service.currentTrack;

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.tealAccent.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.4)),
                      ),
                      child: Icon(
                        currentTrack.isLocal ? Icons.music_note : Icons.cloud_queue,
                        color: Colors.tealAccent,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentTrack.title,
                            style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${currentTrack.artist} • ${currentTrack.durationDesc}',
                            style: const TextStyle(color: Colors.white70, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: currentTrack.isLocal ? Colors.green.withValues(alpha: 0.2) : Colors.purple.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        currentTrack.tag,
                        style: TextStyle(
                          color: currentTrack.isLocal ? Colors.greenAccent : Colors.purpleAccent,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // Progress Slider & Live Times
          StreamBuilder<Duration>(
            stream: _service.player.positionStream,
            builder: (context, posSnap) {
              final pos = posSnap.data ?? Duration.zero;
              final total = _service.player.duration ?? const Duration(seconds: 3);
              final maxSec = total.inMilliseconds.toDouble();
              final curSec = pos.inMilliseconds.toDouble().clamp(0.0, maxSec);

              return Column(
                children: [
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      trackHeight: 3,
                      activeTrackColor: Colors.tealAccent,
                      inactiveTrackColor: Colors.white12,
                      thumbColor: Colors.tealAccent,
                      overlayColor: Colors.tealAccent.withValues(alpha: 0.2),
                    ),
                    child: Slider(
                      value: curSec,
                      min: 0.0,
                      max: maxSec > 0 ? maxSec : 1.0,
                      onChanged: (val) {
                        _service.seek(Duration(milliseconds: val.toInt()));
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatDuration(pos), style: const TextStyle(color: Colors.white70, fontSize: 10, fontFamily: 'monospace')),
                        Text(_formatDuration(total), style: const TextStyle(color: Colors.white54, fontSize: 10, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          // Primary Transport Buttons (Previous, Play/Pause, Next, Stop)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 28,
                icon: const Icon(Icons.skip_previous, color: Colors.white),
                onPressed: () => _service.skipToPrevious(),
                tooltip: '上一曲',
              ),
              const SizedBox(width: 14),
              StreamBuilder<PlayerState>(
                stream: _service.player.playerStateStream,
                builder: (context, snapshot) {
                  final playing = snapshot.data?.playing ?? false;
                  return ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      shape: const CircleBorder(),
                      padding: const EdgeInsets.all(14),
                      backgroundColor: Colors.tealAccent,
                      foregroundColor: Colors.black,
                      elevation: 4,
                    ),
                    onPressed: () {
                      if (playing) {
                        _service.pause();
                      } else {
                        _service.play();
                      }
                    },
                    child: Icon(
                      playing ? Icons.pause : Icons.play_arrow,
                      size: 28,
                      color: Colors.black,
                    ),
                  );
                },
              ),
              const SizedBox(width: 14),
              IconButton(
                iconSize: 28,
                icon: const Icon(Icons.skip_next, color: Colors.white),
                onPressed: () => _service.skipToNext(),
                tooltip: '下一曲',
              ),
              const SizedBox(width: 10),
              IconButton(
                iconSize: 24,
                icon: const Icon(Icons.stop, color: Colors.white70),
                onPressed: () => _service.stop(),
                tooltip: '停止',
              ),
            ],
          ),

          // Loop Mode, Shuffle & Safe Test Row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Real Loop Mode Button
              StreamBuilder<LoopMode>(
                stream: _service.player.loopModeStream,
                builder: (context, snap) {
                  final mode = snap.data ?? LoopMode.all;
                  IconData icon = Icons.repeat;
                  String label = '列表循环';
                  Color col = Colors.tealAccent;

                  if (mode == LoopMode.one) {
                    icon = Icons.repeat_one;
                    label = '单曲循环';
                    col = Colors.amberAccent;
                  } else if (mode == LoopMode.off) {
                    icon = Icons.trending_flat;
                    label = '顺序单次';
                    col = Colors.white54;
                  }

                  return OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      side: BorderSide(color: col.withValues(alpha: 0.5)),
                    ),
                    icon: Icon(icon, size: 14, color: col),
                    label: Text(label, style: TextStyle(color: col, fontSize: 10.5)),
                    onPressed: () => _service.cycleLoopMode(),
                  );
                },
              ),

              // Real Shuffle Mode Button
              StreamBuilder<bool>(
                stream: _service.player.shuffleModeEnabledStream,
                builder: (context, snap) {
                  final enabled = snap.data ?? false;
                  final col = enabled ? Colors.cyanAccent : Colors.white54;
                  return OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      side: BorderSide(color: col.withValues(alpha: 0.5)),
                    ),
                    icon: Icon(Icons.shuffle, size: 14, color: col),
                    label: Text(enabled ? '随机: 开' : '随机: 关', style: TextStyle(color: col, fontSize: 10.5)),
                    onPressed: () => _service.toggleShuffle(),
                  );
                },
              ),

              // Safe 3-Second Test Playback
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E3846),
                  foregroundColor: Colors.tealAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                icon: const Icon(Icons.timer_outlined, size: 14),
                label: const Text('3秒安全试播', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold)),
                onPressed: () {
                  _service.testShortPlayback(duration: const Duration(seconds: 3));
                },
              ),
            ],
          ),

          // Safe Volume Control
          Row(
            children: [
              const Icon(Icons.volume_down, size: 16, color: Colors.white54),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                    trackHeight: 2,
                    activeTrackColor: Colors.tealAccent.withValues(alpha: 0.7),
                    inactiveTrackColor: Colors.white12,
                    thumbColor: Colors.tealAccent,
                  ),
                  child: Slider(
                    value: _service.currentVolume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (val) {
                      setState(() {
                        _service.setVolume(val);
                      });
                    },
                  ),
                ),
              ),
              Text(
                '${(_service.currentVolume * 100).toInt()}% (安全低音量)',
                style: const TextStyle(color: Colors.white60, fontSize: 9.5),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistCard() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF181C24),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '音频样本列表 (点击即切歌)',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('ExoPlayer 解码', style: TextStyle(color: Colors.lightBlueAccent, fontSize: 9)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Tracks List
          Expanded(
            child: StreamBuilder<int?>(
              stream: _service.player.currentIndexStream,
              builder: (context, snapshot) {
                final currentIdx = snapshot.data ?? 0;
                return ListView.builder(
                  itemCount: _service.tracks.length,
                  itemBuilder: (context, i) {
                    final item = _service.tracks[i];
                    final isSelected = currentIdx == i;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      decoration: BoxDecoration(
                        color: isSelected ? Colors.tealAccent.withValues(alpha: 0.12) : Colors.black26,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isSelected ? Colors.tealAccent.withValues(alpha: 0.6) : Colors.transparent,
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        leading: CircleAvatar(
                          radius: 12,
                          backgroundColor: isSelected ? Colors.tealAccent : Colors.white12,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: isSelected ? Colors.black : Colors.white70,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        title: Text(
                          item.title,
                          style: TextStyle(
                            color: isSelected ? Colors.tealAccent : Colors.white,
                            fontSize: 11.5,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${item.durationDesc} • ${item.isLocal ? "离线资产" : "公网流"}',
                          style: const TextStyle(color: Colors.white54, fontSize: 9.5),
                        ),
                        trailing: Icon(
                          isSelected ? Icons.equalizer : Icons.play_arrow,
                          size: 16,
                          color: isSelected ? Colors.tealAccent : Colors.white30,
                        ),
                        onTap: () => _service.selectTrack(i),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          // Environment and AudioFocus Notice
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: Colors.black38,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white10),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '• 本地离线验证：前3首为自制WAV合成音，完全本地解码不受DNS影响',
                  style: TextStyle(color: Colors.white70, fontSize: 9.5),
                ),
                Text(
                  '• 焦点与导航保护：已配置 AudioSession.music，实测低音量不抢占系统',
                  style: TextStyle(color: Colors.white70, fontSize: 9.5),
                ),
                Text(
                  '• 远程播控支持：兼容 R9000P WebSocket (/api/v1/ws/music) 与 HTTP 206 流式接口',
                  style: TextStyle(color: Colors.tealAccent, fontSize: 9.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
