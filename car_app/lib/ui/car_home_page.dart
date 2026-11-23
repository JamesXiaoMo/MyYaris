import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import '../models/music_queue_models.dart';
import '../models/obd_telemetry.dart';
import '../models/task_model.dart';
import '../services/built_in_player_service.dart';
import '../services/car_music_queue_controller.dart';
import '../services/car_music_sync_service.dart';
import '../services/car_obd_service.dart';
import '../services/car_voice_assistant_service.dart';
import '../services/storage_service.dart';
import '../services/task_poller_service.dart';
import 'car_dashboard_mode_page.dart';
import 'car_music_tab.dart';
import 'car_obd_tab.dart';
import 'car_settings_tab.dart';
import 'yaris_car_theme.dart';

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
  final BuiltInPlayerService _playerService = BuiltInPlayerService();
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
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
    _playerService.init();
    CarObdService().startAutoConnectLoop();
  }

  String _formatDuration(Duration d) {
    final sec = d.inSeconds < 0 ? 0 : d.inSeconds;
    final m = (sec ~/ 60).toString();
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _modeLabel(PlaybackMode mode) {
    switch (mode) {
      case PlaybackMode.listLoop:
        return '喜欢歌单循环';
      case PlaybackMode.shuffle:
        return '喜欢歌单随机';
      case PlaybackMode.intelligence:
        return '网易云心动';
      case PlaybackMode.singleLoop:
        return '单曲循环';
    }
  }

  Future<void> _relaunchLatestNav(TaskModel task) async {
    final ok = await widget.poller.relaunchNavigation(task);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? '正在打开 NAVITIME：${task.title}' : '未能唤起 NAVITIME，请确认车机已安装该应用'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YarisCarTheme.canvas,
      body: SafeArea(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildNavigationRail(),
            Expanded(
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: IndexedStack(
                      index: _selectedTab,
                      children: [
                        _buildHomeDashboard(),
                        CarMusicTab(storage: widget.storage),
                        const CarObdTab(),
                        CarSettingsTab(
                          storage: widget.storage,
                          poller: widget.poller,
                          onOpenObdTab: () => setState(() => _selectedTab = 2),
                        ),
                      ],
                    ),
                  ),
                  _buildVoiceAssistantBanner(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationRail() {
    const items = [
      (icon: Icons.home_rounded, label: '首页'),
      (icon: Icons.music_note_rounded, label: '音乐'),
      (icon: Icons.directions_car_rounded, label: '车况'),
      (icon: Icons.settings_rounded, label: '设置'),
    ];

    return Container(
      width: 96,
      decoration: const BoxDecoration(
        color: YarisCarTheme.paper,
        border: Border(right: BorderSide(color: YarisCarTheme.line, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      child: Column(
        children: [
          const SizedBox(height: 4),
          for (int i = 0; i < items.length; i++) ...[
            _RailItem(
              icon: items[i].icon,
              label: items[i].label,
              selected: _selectedTab == i,
              onTap: () => setState(() => _selectedTab = i),
            ),
            const SizedBox(height: 8),
          ],
          const Spacer(),
          ListenableBuilder(
            listenable: CarVoiceAssistantService(),
            builder: (context, _) {
              final voice = CarVoiceAssistantService();
              final recording = voice.isRecording;
              final busy = voice.isBusy;
              final bg = recording
                  ? YarisCarTheme.red
                  : (busy ? YarisCarTheme.red.withValues(alpha: 0.14) : Colors.transparent);
              final fg = recording
                  ? Colors.white
                  : (busy ? YarisCarTheme.red : YarisCarTheme.ink);
              return Material(
                color: bg,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: busy ? null : () => voice.toggleVoice(widget.storage),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: recording
                            ? YarisCarTheme.red
                            : YarisCarTheme.red.withValues(alpha: 0.35),
                        width: 1.2,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          recording
                              ? Icons.stop_rounded
                              : (busy ? Icons.graphic_eq_rounded : Icons.mic_rounded),
                          color: fg,
                          size: 24,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          recording
                              ? '结束'
                              : (voice.state == VoiceAssistantState.thinking
                                  ? '思考中'
                                  : (voice.state == VoiceAssistantState.speaking
                                      ? '播报中'
                                      : '语音')),
                          style: TextStyle(
                            color: fg,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          _RailItem(
            icon: Icons.speed_rounded,
            label: '仪表',
            selected: false,
            onTap: () => Navigator.push<void>(
              context,
              MaterialPageRoute(builder: (_) => const CarDashboardModePage()),
            ),
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<bool>(
            valueListenable: CarMusicSyncService().isHealthyNotifier,
            builder: (context, healthy, _) {
              final online = healthy;
              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: online ? YarisCarTheme.green : YarisCarTheme.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    online ? '在线' : '离线',
                    style: TextStyle(
                      color: online ? YarisCarTheme.green : YarisCarTheme.muted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceAssistantBanner() {
    return ListenableBuilder(
      listenable: CarVoiceAssistantService(),
      builder: (context, _) {
        final voice = CarVoiceAssistantService();
        if (!voice.bannerVisible) return const SizedBox.shrink();
        final isRec = voice.isRecording;
        final isErr = voice.state == VoiceAssistantState.error;
        return Positioned(
          left: 20,
          right: 20,
          top: 16,
          child: Material(
            color: const Color(0xF0121826),
            elevation: 10,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isRec
                      ? YarisCarTheme.red
                      : (isErr ? Colors.orangeAccent : const Color(0xFF2D3B5E)),
                  width: 1.4,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isRec
                            ? Icons.mic_rounded
                            : (voice.isBusy
                                ? Icons.auto_awesome_rounded
                                : Icons.assistant_rounded),
                        color: isRec ? YarisCarTheme.red : const Color(0xFF4C9BFF),
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          voice.statusText.isNotEmpty ? voice.statusText : 'AI 语音助手',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (isRec)
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: YarisCarTheme.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                          ),
                          onPressed: () => voice.toggleVoice(widget.storage),
                          icon: const Icon(Icons.stop_rounded, size: 18),
                          label: const Text('说完发送'),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: Colors.white70),
                          onPressed: voice.dismissBanner,
                          tooltip: '关闭',
                        ),
                    ],
                  ),
                  if (voice.transcript.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '你说：${voice.transcript}',
                      style: const TextStyle(
                        color: Color(0xFF9FB0D1),
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                  if (voice.replyText.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      voice.replyText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (voice.candidates.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        for (int i = 0; i < voice.candidates.length; i++)
                          ActionChip(
                            backgroundColor: const Color(0xFF1F2B46),
                            side: const BorderSide(color: Color(0xFF3E5485)),
                            label: Text(
                              '${i + 1}. ${voice.candidates[i].name}'
                              '${voice.candidates[i].distanceKm != null ? ' · ${voice.candidates[i].distanceKm!.toStringAsFixed(1)}km' : ''}'
                              '${voice.candidates[i].rating != null ? ' · ${voice.candidates[i].rating!.toStringAsFixed(1)}★' : ''}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onPressed: () => voice.selectCandidate(widget.storage, i + 1),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHomeDashboard() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left Column (~52%): Vehicle Hero + OBD summary (top) & Phone Navigation Receive (bottom)
        Expanded(
          flex: 52,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 62,
                child: _buildVehicleHeroCard(),
              ),
              const SizedBox(height: 12),
              Expanded(
                flex: 38,
                child: _buildNavReceiveCard(),
              ),
            ],
          ),
        ),
        const SizedBox(width: 14),
        // Right Column (~48%): Now Playing Card
        Expanded(
          flex: 48,
          child: _buildHomeMusicCard(),
        ),
      ],
    );
  }

  Widget _buildVehicleHeroCard() {
    return ValueListenableBuilder<ObdTelemetry>(
      valueListenable: CarObdService().telemetryNotifier,
      builder: (context, tel, _) {
        final obdReady = tel.status == ObdConnectionStatus.ready;
        return GestureDetector(
          onTap: () => setState(() => _selectedTab = 2),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [YarisCarTheme.periwinkle, Color(0xFFF3F5FF)],
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: YarisCarTheme.line, width: 1),
            ),
            child: Column(
              children: [
                // Top badges
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: YarisCarTheme.paper.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: YarisCarTheme.blue.withValues(alpha: 0.2)),
                      ),
                      child: const Text(
                        'HYBRID',
                        style: TextStyle(
                          color: YarisCarTheme.periwinkleDark,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    YarisStatusPill(
                      text: obdReady ? 'OBD 在线' : 'OBD 未连接',
                      color: obdReady ? YarisCarTheme.green : YarisCarTheme.muted,
                      backgroundColor: YarisCarTheme.paper.withValues(alpha: 0.9),
                      showDot: true,
                    ),
                  ],
                ),
                // YARIS typography + Red Yaris Poster
                Expanded(
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      const Positioned(
                        top: 2,
                        child: Text(
                          'YARIS',
                          style: TextStyle(
                            color: YarisCarTheme.blue,
                            fontSize: 54,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2,
                            height: 1.0,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Image.asset(
                          'assets/images/yaris-model-poster.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.directions_car_filled_rounded,
                            size: 64,
                            color: YarisCarTheme.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // 3-Metric OBD Summary Strip: Speed, Remaining Fuel, Trip Distance since start
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: YarisCarTheme.paper.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      _MiniMetric(
                        label: '车速',
                        value: tel.speedKmh != null ? '${tel.speedKmh!.toInt()} km/h' : '—',
                      ),
                      _MiniDivider(),
                      _MiniMetric(
                        label: '剩余油量',
                        value: tel.fuelLevelLiters != null
                            ? '${tel.fuelLevelLiters!.toStringAsFixed(1)} L'
                            : (tel.fuelLevelPercent != null
                                ? '${tel.fuelLevelPercent!.toStringAsFixed(0)}%'
                                : '—'),
                      ),
                      _MiniDivider(),
                      _MiniMetric(
                        label: '本次里程',
                        value: tel.tripDistanceKm != null
                            ? '${tel.tripDistanceKm!.toStringAsFixed(1)} km'
                            : '—',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildNavReceiveCard() {
    return ListenableBuilder(
      listenable: widget.poller,
      builder: (context, _) {
        final isRunning = widget.poller.isRunning;
        final recent = widget.poller.recentTasks;
        final latest = recent.isNotEmpty ? recent.first : null;

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: YarisCarTheme.cardDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '手机导航接收',
                    style: TextStyle(
                      color: YarisCarTheme.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  YarisStatusPill(
                    text: isRunning ? '接收中' : '已暂停',
                    color: isRunning ? YarisCarTheme.blue : YarisCarTheme.muted,
                    backgroundColor:
                        isRunning ? YarisCarTheme.periwinkle : YarisCarTheme.neutral,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 38,
                      decoration: const BoxDecoration(
                        color: YarisCarTheme.periwinkle,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.location_on_rounded,
                        color: YarisCarTheme.blue,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          latest?.title ?? '等待手机发送目的地',
                          style: const TextStyle(
                            color: YarisCarTheme.ink,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 38,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: YarisCarTheme.blue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: YarisCarTheme.neutral,
                    disabledForegroundColor: YarisCarTheme.muted,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  onPressed: latest != null ? () => _relaunchLatestNav(latest) : null,
                  child: const Text(
                    '打开 NAVITIME',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHomeMusicCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: YarisCarTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header + Active Mode Pill
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '正在播放',
                style: TextStyle(
                  color: YarisCarTheme.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              ValueListenableBuilder<PlaybackMode>(
                valueListenable: CarMusicQueueController().appliedModeNotifier,
                builder: (context, mode, _) {
                  return YarisStatusPill(
                    text: _modeLabel(mode),
                    color: mode == PlaybackMode.intelligence
                        ? YarisCarTheme.red
                        : YarisCarTheme.blue,
                    backgroundColor: mode == PlaybackMode.intelligence
                        ? YarisCarTheme.rose
                        : YarisCarTheme.periwinkle,
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Artwork + Track info
          ValueListenableBuilder(
            valueListenable: CarMusicQueueController().currentTrackNotifier,
            builder: (context, _, _) {
              return StreamBuilder<int?>(
                stream: _playerService.player.currentIndexStream,
                builder: (context, _) {
                  final track = _playerService.currentTrack;
                  final hasTrack = track.id.isNotEmpty && track.title != '无播放曲目';
                  return Row(
                    children: [
                      YarisMusicArtwork(
                        size: 80,
                        borderRadius: 18,
                        coverUrl: hasTrack ? track.coverUrl : null,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasTrack ? track.title : '点击播放开始听歌',
                              style: const TextStyle(
                                color: YarisCarTheme.ink,
                                fontSize: 17.5,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (hasTrack && track.artist.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                track.artist,
                                style: const TextStyle(color: YarisCarTheme.muted, fontSize: 12.5),
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

          const Spacer(),

          // Progress bar
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
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      activeTrackColor: YarisCarTheme.blue,
                      inactiveTrackColor: YarisCarTheme.neutral,
                      thumbColor: YarisCarTheme.blue,
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
                          style: const TextStyle(color: YarisCarTheme.muted, fontSize: 11),
                        ),
                        Text(
                          total.inMilliseconds > 0 ? _formatDuration(total) : '--:--',
                          style: const TextStyle(color: YarisCarTheme.muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 6),

          // Transport Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 28,
                color: YarisCarTheme.ink,
                tooltip: '上一曲',
                onPressed: () => CarMusicSyncService().requestLocalCommand('prev'),
                icon: const Icon(Icons.skip_previous_rounded),
              ),
              const SizedBox(width: 16),
              StreamBuilder<PlayerState>(
                stream: _playerService.player.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? false;
                  return SizedBox(
                    width: 54,
                    height: 54,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero,
                        backgroundColor: YarisCarTheme.blue,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () =>
                          CarMusicSyncService().requestLocalCommand(playing ? 'pause' : 'resume'),
                      child: Icon(
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        size: 30,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(width: 16),
              IconButton(
                iconSize: 28,
                color: YarisCarTheme.ink,
                tooltip: '下一曲',
                onPressed: () => CarMusicSyncService().requestLocalCommand('next'),
                icon: const Icon(Icons.skip_next_rounded),
              ),
            ],
          ),

          const Spacer(),

          // Mode pills
          ValueListenableBuilder<PlaybackMode>(
            valueListenable: CarMusicQueueController().appliedModeNotifier,
            builder: (context, mode, _) {
              return Row(
                children: [
                  Expanded(
                    child: _HomeModeChip(
                      label: '喜欢循环',
                      selected: mode == PlaybackMode.listLoop,
                      onTap: () => CarMusicSyncService()
                          .requestLocalCommand('set_playback_mode', {'mode': 'list_loop'}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _HomeModeChip(
                      label: '喜欢随机',
                      selected: mode == PlaybackMode.shuffle,
                      onTap: () => CarMusicSyncService()
                          .requestLocalCommand('set_playback_mode', {'mode': 'shuffle'}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _HomeModeChip(
                      label: '网易云心动',
                      selected: mode == PlaybackMode.intelligence,
                      isHeart: true,
                      onTap: () => CarMusicSyncService()
                          .requestLocalCommand('set_playback_mode', {'mode': 'intelligence'}),
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 10),
          const Divider(height: 1, color: YarisCarTheme.line),
          const SizedBox(height: 8),

          // Bottom Safe Volume + Queue Entry
          Row(
            children: [
              Text(
                '音量 ${(_playerService.currentVolume * 100).toInt()}%',
                style: const TextStyle(
                  color: YarisCarTheme.muted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                    activeTrackColor: YarisCarTheme.blue,
                    inactiveTrackColor: YarisCarTheme.neutral,
                    thumbColor: YarisCarTheme.blue,
                  ),
                  child: Slider(
                    value: _playerService.currentVolume,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) {
                      setState(() => _playerService.setVolume(v));
                    },
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _selectedTab = 1),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '播放队列',
                        style: TextStyle(
                          color: YarisCarTheme.ink,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, size: 16, color: YarisCarTheme.muted),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? YarisCarTheme.periwinkle : Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? YarisCarTheme.blue : YarisCarTheme.muted,
              ),
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  color: selected ? YarisCarTheme.blue : YarisCarTheme.ink,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;

  const _MiniMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: YarisCarTheme.ink,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: YarisCarTheme.muted, fontSize: 10.5),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _MiniDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      color: YarisCarTheme.line,
    );
  }
}

class _HomeModeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isHeart;
  final VoidCallback onTap;

  const _HomeModeChip({
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
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isHeart) ...[
                Icon(Icons.favorite_rounded, size: 13, color: fg),
                const SizedBox(width: 3),
              ],
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(color: fg, fontSize: 11.5, fontWeight: FontWeight.w600),
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
