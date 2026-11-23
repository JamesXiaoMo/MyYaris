import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/obd_telemetry.dart';
import '../services/built_in_player_service.dart';
import '../services/car_music_queue_controller.dart';
import '../services/car_obd_service.dart';
import 'yaris_car_theme.dart';

/// Full-screen Cyber / Hybrid Cockpit Instrument Cluster HUD for OttoAibox P3 Pro.
class CarDashboardModePage extends StatefulWidget {
  const CarDashboardModePage({super.key});

  @override
  State<CarDashboardModePage> createState() => _CarDashboardModePageState();
}

class _CarDashboardModePageState extends State<CarDashboardModePage> {
  final BuiltInPlayerService _player = BuiltInPlayerService();
  double _prevSpeedKmh = 0;
  DateTime _prevTime = DateTime.now();
  double _longitudinalG = 0;
  late final VoidCallback _obdListener;

  @override
  void initState() {
    super.initState();
    _obdListener = _onTelemetryUpdate;
    CarObdService().telemetryNotifier.addListener(_obdListener);
  }

  void _onTelemetryUpdate() {
    final t = CarObdService().currentTelemetry;
    final spd = t.speedKmh;
    if (spd == null) return;
    final now = DateTime.now();
    final dt = now.difference(_prevTime).inMilliseconds / 1000.0;
    if (dt >= 0.4 && dt <= 8.0) {
      final dvMs = (spd - _prevSpeedKmh) / 3.6;
      final g = (dvMs / dt) / 9.81;
      if (mounted) {
        setState(() {
          _longitudinalG = (_longitudinalG * 0.4 + g * 0.6).clamp(-1.0, 1.0);
        });
      }
    }
    _prevSpeedKmh = spd;
    _prevTime = now;
  }

  @override
  void dispose() {
    CarObdService().telemetryNotifier.removeListener(_obdListener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF070A12),
      body: SafeArea(
        child: ValueListenableBuilder<ObdTelemetry>(
          valueListenable: CarObdService().telemetryNotifier,
          builder: (context, t, _) {
            final speed = t.speedKmh ?? 0.0;
            final rpm = t.engineRpm ?? 0.0;
            final isEv = speed >= 1.0 && rpm < 100.0;
            final fuelPct = t.fuelLevelPercent ??
                (t.fuelLevelLiters != null ? (t.fuelLevelLiters! / 36.0) * 100.0 : null);
            final coolant = t.coolantTemp;
            final v12 = t.aux12vVoltage;
            final load = t.engineLoad;

            return Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
              child: Column(
                children: [
                  // Top cyber header
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF2E4C).withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0xFFFF2E4C).withValues(alpha: 0.65),
                          ),
                        ),
                        child: const Text(
                          'YARIS HYBRID // CYBER HUD',
                          style: TextStyle(
                            color: Color(0xFFFF4D67),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (isEv)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E676).withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: const Color(0xFF00E676)),
                          ),
                          child: const Text(
                            'EV MODE',
                            style: TextStyle(
                              color: Color(0xFF00E676),
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ),
                      const Spacer(),
                      if (t.ambientAirTemp != null)
                        Text(
                          '车外 ${t.ambientAirTemp!.toStringAsFixed(0)}°C   ',
                          style: const TextStyle(
                            color: Color(0xFF7B8CA8),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Color(0xFF253047)),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_fullscreen_rounded, size: 16),
                        label: const Text('退出仪表'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // Main 3-column HUD
                  Expanded(
                    child: Row(
                      children: [
                        // Left: G-Force Ball + Vitals
                        Expanded(
                          flex: 3,
                          child: Column(
                            children: [
                              Expanded(
                                flex: 6,
                                child: _CyberCard(
                                  title: 'G-FORCE',
                                  child: Center(
                                    child: CustomPaint(
                                      size: const Size(140, 140),
                                      painter: _GForcePainter(_longitudinalG),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                flex: 4,
                                child: _CyberCard(
                                  title: 'VITALS',
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                                    children: [
                                      _CyberMiniMetric(
                                        label: '水温',
                                        value: coolant != null ? '${coolant.round()}°C' : '--',
                                        color: const Color(0xFF00E5FF),
                                      ),
                                      _CyberMiniMetric(
                                        label: '12V',
                                        value: v12 != null ? '${v12.toStringAsFixed(1)}V' : '--',
                                        color: const Color(0xFF00E676),
                                      ),
                                      _CyberMiniMetric(
                                        label: '负荷',
                                        value: load != null ? '${load.round()}%' : '--',
                                        color: const Color(0xFFFFB300),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),

                        // Center: Giant Speedometer + RPM Arc
                        Expanded(
                          flex: 5,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const RadialGradient(
                                colors: [Color(0xFF121A2C), Color(0xFF090D18)],
                                radius: 0.9,
                              ),
                              borderRadius: BorderRadius.circular(28),
                              border: Border.all(
                                color: const Color(0xFF1F2D4A),
                                width: 1.5,
                              ),
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                CustomPaint(
                                  size: const Size(310, 310),
                                  painter: _CyberArcGaugePainter(
                                    speedKmh: speed,
                                    rpm: rpm,
                                    isEv: isEv,
                                  ),
                                ),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      speed.round().toString(),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 92,
                                        fontWeight: FontWeight.w900,
                                        height: 0.95,
                                        letterSpacing: -2,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    const Text(
                                      'KM / H',
                                      style: TextStyle(
                                        color: Color(0xFF00E5FF),
                                        fontSize: 15,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 3,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    Text(
                                      rpm > 0 ? '${rpm.round()} RPM' : (isEv ? 'ELECTRIC DRIVE' : 'READY'),
                                      style: TextStyle(
                                        color: isEv
                                            ? const Color(0xFF00E676)
                                            : const Color(0xFF8A9AB8),
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),

                        // Right: Fuel / Range + Mini Music Control
                        Expanded(
                          flex: 3,
                          child: Column(
                            children: [
                              Expanded(
                                flex: 5,
                                child: _CyberCard(
                                  title: 'FUEL & ODO',
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            t.fuelLevelLiters != null
                                                ? '${t.fuelLevelLiters!.toStringAsFixed(1)} L'
                                                : '-- L',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 22,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          Text(
                                            fuelPct != null ? '${fuelPct.round()}%' : '--',
                                            style: const TextStyle(
                                              color: Color(0xFFFF4D67),
                                              fontSize: 15,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: LinearProgressIndicator(
                                          value: ((fuelPct ?? 0) / 100.0).clamp(0.0, 1.0),
                                          minHeight: 8,
                                          backgroundColor: const Color(0xFF1C2538),
                                          color: const Color(0xFF00E5FF),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        '总里程 ${t.totalOdometerKm != null ? "${t.totalOdometerKm!.round()} km" : "--"}',
                                        style: const TextStyle(
                                          color: Color(0xFF8A9AB8),
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                              Expanded(
                                flex: 5,
                                child: _CyberCard(
                                  title: 'NOW PLAYING',
                                  child: ValueListenableBuilder(
                                    valueListenable: CarMusicQueueController().currentTrackNotifier,
                                    builder: (context, _, _) {
                                      final track = _player.currentTrack;
                                      final hasTrack = track.id.isNotEmpty && track.title != '无播放曲目';
                                      return Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Row(
                                            children: [
                                              YarisMusicArtwork(
                                                size: 44,
                                                borderRadius: 10,
                                                coverUrl: hasTrack ? track.coverUrl : null,
                                              ),
                                              const SizedBox(width: 10),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      hasTrack ? track.title : '等待播放',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 13.5,
                                                        fontWeight: FontWeight.w700,
                                                      ),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                    Text(
                                                      hasTrack ? track.artist : '—',
                                                      style: const TextStyle(
                                                        color: Color(0xFF8A9AB8),
                                                        fontSize: 11.5,
                                                      ),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          StreamBuilder<bool>(
                                            stream: _player.player.playingStream,
                                            builder: (context, snap) {
                                              final playing = snap.data ?? _player.player.playing;
                                              return Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                                children: [
                                                  IconButton(
                                                    onPressed: _player.skipToPrevious,
                                                    icon: const Icon(Icons.skip_previous_rounded, color: Colors.white70),
                                                  ),
                                                  IconButton(
                                                    onPressed: () {
                                                      if (playing) {
                                                        _player.pause();
                                                      } else {
                                                        unawaited(_player.play());
                                                      }
                                                    },
                                                    icon: Icon(
                                                      playing ? Icons.pause_circle_filled_rounded : Icons.play_circle_filled_rounded,
                                                      color: const Color(0xFF00E5FF),
                                                      size: 34,
                                                    ),
                                                  ),
                                                  IconButton(
                                                    onPressed: _player.skipToNext,
                                                    icon: const Icon(Icons.skip_next_rounded, color: Colors.white70),
                                                  ),
                                                ],
                                              );
                                            },
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CyberCard extends StatelessWidget {
  const _CyberCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1422),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF1E2940)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFF5D6F91),
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _CyberMiniMetric extends StatelessWidget {
  const _CyberMiniMetric({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          value,
          style: TextStyle(color: color, fontSize: 17, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF7B8CA8), fontSize: 11),
        ),
      ],
    );
  }
}

class _CyberArcGaugePainter extends CustomPainter {
  _CyberArcGaugePainter({
    required this.speedKmh,
    required this.rpm,
    required this.isEv,
  });
  final double speedKmh;
  final double rpm;
  final bool isEv;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 14;
    const startAngle = math.pi * 0.75;
    const sweepAngle = math.pi * 1.5;

    final trackPaint = Paint()
      ..color = const Color(0xFF1A2438)
      ..strokeWidth = 14
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      trackPaint,
    );

    final speedFrac = (speedKmh / 160.0).clamp(0.0, 1.0);
    final activePaint = Paint()
      ..shader = const SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [Color(0xFF00E5FF), Color(0xFF3548E8), Color(0xFFFF2E4C)],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..strokeWidth = 14
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    if (speedFrac > 0.005) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        sweepAngle * speedFrac,
        false,
        activePaint,
      );
    }

    // Inner RPM / EV ring
    final innerR = radius - 22;
    final rpmFrac = isEv ? 0.35 : (rpm / 6000.0).clamp(0.0, 1.0);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: innerR),
      startAngle,
      sweepAngle,
      false,
      Paint()
        ..color = const Color(0xFF141C2D)
        ..strokeWidth = 5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    );
    if (rpmFrac > 0.01) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: innerR),
        startAngle,
        sweepAngle * rpmFrac,
        false,
        Paint()
          ..color = isEv ? const Color(0xFF00E676) : const Color(0xFFFFB300)
          ..strokeWidth = 5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CyberArcGaugePainter oldDelegate) =>
      oldDelegate.speedKmh != speedKmh ||
      oldDelegate.rpm != rpm ||
      oldDelegate.isEv != isEv;
}

class _GForcePainter extends CustomPainter {
  _GForcePainter(this.longitudinalG);
  final double longitudinalG;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2 - 8;
    final grid = Paint()
      ..color = const Color(0xFF23304A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.drawCircle(c, r, grid);
    canvas.drawCircle(c, r * 0.5, grid);
    canvas.drawLine(Offset(c.dx - r, c.dy), Offset(c.dx + r, c.dy), grid);
    canvas.drawLine(Offset(c.dx, c.dy - r), Offset(c.dx, c.dy + r), grid);

    // Positive accel pushes dot down, braking pushes dot up
    final dy = (longitudinalG.clamp(-0.8, 0.8) / 0.8) * (r - 10);
    final dot = Offset(c.dx, c.dy + dy);
    final color = longitudinalG >= 0 ? const Color(0xFF00E5FF) : const Color(0xFFFF2E4C);
    canvas.drawCircle(dot, 13, Paint()..color = color.withValues(alpha: 0.25));
    canvas.drawCircle(dot, 7, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _GForcePainter oldDelegate) =>
      oldDelegate.longitudinalG != longitudinalG;
}
