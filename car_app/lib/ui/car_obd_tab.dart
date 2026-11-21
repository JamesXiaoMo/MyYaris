import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/obd_telemetry.dart';
import '../services/car_obd_service.dart';
import 'yaris_car_theme.dart';

/// Clean user-facing OBD vehicle telemetry tab (zero debug terminals or scan tools).
class CarObdTab extends StatefulWidget {
  const CarObdTab({super.key});

  @override
  State<CarObdTab> createState() => _CarObdTabState();
}

class _CarObdTabState extends State<CarObdTab> {
  final CarObdService _obd = CarObdService();

  Future<void> _scanAndSelectDevice() async {
    await _obd.startScan();
    if (!mounted) return;
    await _showDeviceSelectDialog(_obd.scanResultsNotifier.value);
  }

  Future<void> _showDeviceSelectDialog(List<ScanResult> results) async {
    List<BluetoothDevice> bonded = [];
    try {
      bonded = await FlutterBluePlus.bondedDevices;
    } catch (_) {}

    final allDevices = <_ObdDeviceChoice>[];
    final seen = <String>{};

    for (final b in bonded) {
      final id = b.remoteId.str.toUpperCase();
      final name = b.platformName.isNotEmpty ? b.platformName : '已配对设备 ($id)';
      allDevices.add(_ObdDeviceChoice(
        device: b,
        name: name,
        subtitle: '系统已配对 · $id',
        isBonded: true,
      ));
      seen.add(id);
    }

    for (final r in results) {
      final id = r.device.remoteId.str.toUpperCase();
      if (!seen.contains(id)) {
        final name = r.device.platformName.isNotEmpty ? r.device.platformName : '未知设备 ($id)';
        allDevices.add(_ObdDeviceChoice(
          device: r.device,
          name: name,
          subtitle: '$id · 信号 ${r.rssi} dBm',
          isBonded: false,
        ));
        seen.add(id);
      }
    }

    allDevices.sort((a, b) {
      final aIsObd = a.name.toUpperCase().contains('OBD') || a.name.toUpperCase().contains('VEEPEAK');
      final bIsObd = b.name.toUpperCase().contains('OBD') || b.name.toUpperCase().contains('VEEPEAK');
      if (aIsObd && !bIsObd) return -1;
      if (!aIsObd && bIsObd) return 1;
      if (a.isBonded && !b.isBonded) return -1;
      if (!a.isBonded && b.isBonded) return 1;
      return 0;
    });

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: YarisCarTheme.paper,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.bluetooth_searching_rounded, color: YarisCarTheme.blue, size: 22),
            SizedBox(width: 8),
            Text(
              '选择蓝牙 OBD 设备',
              style: TextStyle(color: YarisCarTheme.ink, fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        content: SizedBox(
          width: 440,
          height: 280,
          child: allDevices.isEmpty
              ? const Center(
                  child: Text(
                    '未发现设备，请确认 OBD 模块已通电并开启车机蓝牙。',
                    style: TextStyle(color: YarisCarTheme.muted, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  itemCount: allDevices.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final item = allDevices[i];
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: YarisCarTheme.cardDecoration(
                        color: YarisCarTheme.canvas,
                        radius: 14,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            item.isBonded ? Icons.bluetooth_connected_rounded : Icons.bluetooth_rounded,
                            color: YarisCarTheme.blue,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.name,
                                  style: const TextStyle(
                                    color: YarisCarTheme.ink,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  item.subtitle,
                                  style: const TextStyle(color: YarisCarTheme.muted, fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: YarisCarTheme.blue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _obd.connect(item.device);
                            },
                            child: const Text('连接', style: TextStyle(fontSize: 12.5)),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(ctx);
              _scanAndSelectDevice();
            },
            child: const Text('重新扫描'),
          ),
        ],
      ),
    );
  }

  String _fmt(double? value, String suffix, {int decimals = 1}) {
    if (value == null) return '—';
    return '${value.toStringAsFixed(decimals)} $suffix';
  }

  String _fmtInt(double? value, String suffix) {
    if (value == null) return '—';
    return '${value.toInt()} $suffix';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ObdTelemetry>(
      valueListenable: _obd.telemetryNotifier,
      builder: (context, tel, _) {
        final isReady = tel.status == ObdConnectionStatus.ready;
        final isBusy = tel.status == ObdConnectionStatus.scanning ||
            tel.status == ObdConnectionStatus.connecting ||
            tel.status == ObdConnectionStatus.initializing;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header bar
            Row(
              children: [
                const Text(
                  '混动与车辆状态',
                  style: TextStyle(
                    color: YarisCarTheme.ink,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                YarisStatusPill(
                  text: isReady
                      ? 'OBD 已连接'
                      : (isBusy ? '正在连接 OBD' : 'OBD 未连接'),
                  color: isReady
                      ? YarisCarTheme.green
                      : (isBusy ? YarisCarTheme.amber : YarisCarTheme.muted),
                  backgroundColor: isReady
                      ? YarisCarTheme.greenBg
                      : (isBusy ? YarisCarTheme.amberBg : YarisCarTheme.neutral),
                  showDot: true,
                ),
                const SizedBox(width: 10),
                if (!isReady)
                  ValueListenableBuilder<bool>(
                    valueListenable: _obd.isScanningNotifier,
                    builder: (context, isScanning, _) {
                      return FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: YarisCarTheme.blue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(999),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                        onPressed: isBusy ? null : _scanAndSelectDevice,
                        icon: Icon(
                          isScanning ? Icons.sync_rounded : Icons.bluetooth_searching_rounded,
                          size: 16,
                        ),
                        label: Text(
                          isScanning ? '扫描中…' : '连接蓝牙 OBD',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      );
                    },
                  )
                else
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: YarisCarTheme.red,
                      side: const BorderSide(color: YarisCarTheme.rose),
                      backgroundColor: YarisCarTheme.rose,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(999),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onPressed: () => _obd.disconnect(),
                    icon: const Icon(Icons.link_off_rounded, size: 16),
                    label: const Text(
                      '断开连接',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            // 2x2 Metric Cards Grid
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _TelemetryCard(
                            title: '动力电池',
                            icon: Icons.battery_charging_full_rounded,
                            metrics: [
                              _MetricPair('电量 SoC', tel.batterySoc != null ? '${tel.batterySoc!.toStringAsFixed(1)}%' : '—'),
                              _MetricPair('电池电压', _fmt(tel.batteryVoltage, 'V')),
                              _MetricPair(
                                '实时电流',
                                tel.batteryCurrent != null
                                    ? '${tel.batteryCurrent! > 0 ? "+" : ""}${tel.batteryCurrent!.toStringAsFixed(1)} A'
                                    : '—',
                              ),
                              _MetricPair('输出功率', _fmt(tel.batteryPowerKw, 'kW', decimals: 2)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _TelemetryCard(
                            title: '发动机与行驶',
                            icon: Icons.speed_rounded,
                            metrics: [
                              _MetricPair('实时车速', _fmtInt(tel.speedKmh, 'km/h')),
                              _MetricPair(
                                '发动机转速',
                                tel.engineRpm != null
                                    ? (tel.engineRpm! < 100 ? 'EV 停机' : '${tel.engineRpm!.toInt()} rpm')
                                    : '—',
                              ),
                              _MetricPair('冷却水温', _fmtInt(tel.coolantTemp, '°C')),
                              _MetricPair('机油温度', _fmtInt(tel.engineOilTemp, '°C')),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: _TelemetryCard(
                            title: '电气与温度',
                            icon: Icons.electrical_services_rounded,
                            metrics: [
                              _MetricPair('12V 蓄电池', _fmt(tel.aux12vVoltage, 'V', decimals: 2)),
                              _MetricPair('变速箱油温', _fmtInt(tel.transaxleOilTemp, '°C')),
                              _MetricPair('车外温度', _fmtInt(tel.ambientAirTemp, '°C')),
                              _MetricPair(
                                '节气门开度',
                                tel.throttlePosition != null
                                    ? '${tel.throttlePosition!.toStringAsFixed(1)}%'
                                    : '—',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: _TelemetryCard(
                            title: '双电机工况',
                            icon: Icons.electric_car_rounded,
                            metrics: [
                              _MetricPair('MG1 转速', _fmtInt(tel.mg1Rpm, 'rpm')),
                              _MetricPair('MG2 转速', _fmtInt(tel.mg2Rpm, 'rpm')),
                              _MetricPair('驱动扭矩', _fmt(tel.mg2Torque, 'Nm')),
                              _MetricPair('再生制动', _fmt(tel.regenBrakingTorque, 'Nm')),
                            ],
                          ),
                        ),
                      ],
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

class _MetricPair {
  final String label;
  final String value;

  const _MetricPair(this.label, this.value);
}

class _TelemetryCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<_MetricPair> metrics;

  const _TelemetryCard({
    required this.title,
    required this.icon,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: YarisCarTheme.cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: YarisCarTheme.periwinkle,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 16, color: YarisCarTheme.blue),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: YarisCarTheme.ink,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (int i = 0; i < metrics.length; i += 2)
                  Row(
                    children: [
                      Expanded(child: _MetricRowItem(pair: metrics[i])),
                      const SizedBox(width: 12),
                      if (i + 1 < metrics.length)
                        Expanded(child: _MetricRowItem(pair: metrics[i + 1]))
                      else
                        const Expanded(child: SizedBox.shrink()),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricRowItem extends StatelessWidget {
  final _MetricPair pair;

  const _MetricRowItem({required this.pair});

  @override
  Widget build(BuildContext context) {
    final isEmpty = pair.value == '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: YarisCarTheme.canvas,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              pair.label,
              style: const TextStyle(color: YarisCarTheme.muted, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            pair.value,
            style: TextStyle(
              color: isEmpty ? YarisCarTheme.muted : YarisCarTheme.ink,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ObdDeviceChoice {
  final BluetoothDevice device;
  final String name;
  final String subtitle;
  final bool isBonded;

  const _ObdDeviceChoice({
    required this.device,
    required this.name,
    required this.subtitle,
    required this.isBonded,
  });
}
