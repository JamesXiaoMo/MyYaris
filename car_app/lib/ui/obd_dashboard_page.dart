import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/obd_telemetry.dart';
import '../services/car_obd_service.dart';
import 'obd_deep_scan_dialog.dart';

class ObdDashboardPage extends StatefulWidget {
  const ObdDashboardPage({super.key});

  @override
  State<ObdDashboardPage> createState() => _ObdDashboardPageState();
}

class _ObdDashboardPageState extends State<ObdDashboardPage> {
  final CarObdService _obd = CarObdService();
  final TextEditingController _customCmdController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();
  bool _showTerminal = false;

  @override
  void dispose() {
    _customCmdController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_logScrollController.hasClients) {
      _logScrollController.animateTo(
        _logScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendQuickCommand(String cmd) async {
    _obd.log('➡️ 用户发送测试指令: $cmd');
    final resp = await _obd.sendRawCommand(cmd);
    _obd.log('⬅️ 指令应答: $resp');
    _scrollToBottom();
  }

  Future<void> _showDeviceSelectDialog(List<ScanResult> results) async {
    List<BluetoothDevice> bonded = [];
    try {
      bonded = await FlutterBluePlus.bondedDevices;
    } catch (_) {}

    final allDevices = <_DeviceItem>[];
    final seen = <String>{};

    for (final b in bonded) {
      final name = b.platformName.isNotEmpty ? b.platformName : '已配对设备 (${b.remoteId.str})';
      allDevices.add(_DeviceItem(
        device: b,
        name: name,
        subtitle: '系统已配对 • MAC: ${b.remoteId.str}',
        isBonded: true,
      ));
      seen.add(b.remoteId.str.toUpperCase());
    }

    for (final r in results) {
      final id = r.device.remoteId.str.toUpperCase();
      if (!seen.contains(id)) {
        final name = r.device.platformName.isNotEmpty
            ? r.device.platformName
            : '未知设备 (${r.device.remoteId.str})';
        allDevices.add(_DeviceItem(
          device: r.device,
          name: name,
          subtitle: 'MAC: ${r.device.remoteId.str} • RSSI: ${r.rssi} dBm',
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

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222B),
        title: const Row(
          children: [
            Icon(Icons.bluetooth_searching, color: Colors.blueAccent, size: 22),
            SizedBox(width: 8),
            Text('选择 OBD 蓝牙设备', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: 480,
          height: 320,
          child: allDevices.isEmpty
              ? const Center(
                  child: Text(
                    '未扫描到设备，请确认 Veepeak OBD 模块已插在车辆 OBD 接口并通电',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: allDevices.length,
                  itemBuilder: (c, i) {
                    final item = allDevices[i];
                    final isVeepeak = item.name.toUpperCase().contains('OBD') ||
                        item.name.toUpperCase().contains('VEEPEAK') ||
                        item.name.toUpperCase().contains('BLE');

                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      leading: Icon(
                        isVeepeak ? Icons.speed : (item.isBonded ? Icons.bluetooth_connected : Icons.bluetooth),
                        color: isVeepeak ? Colors.greenAccent : (item.isBonded ? Colors.blueAccent : Colors.white60),
                        size: 22,
                      ),
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(
                              item.name,
                              style: TextStyle(
                                color: isVeepeak ? Colors.greenAccent : Colors.white,
                                fontWeight: isVeepeak ? FontWeight.bold : FontWeight.normal,
                                fontSize: 13,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (item.isBonded) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.blueAccent.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5), width: 1),
                              ),
                              child: const Text('已配对', style: TextStyle(color: Colors.blueAccent, fontSize: 9.5)),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(
                        item.subtitle,
                        style: const TextStyle(color: Colors.white38, fontSize: 11),
                      ),
                      trailing: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blueAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        ),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _obd.connect(item.device);
                        },
                        child: const Text('连接', style: TextStyle(fontSize: 12)),
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
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重新扫描'),
            onPressed: () {
              Navigator.pop(ctx);
              _obd.startScan();
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101216),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161920),
        elevation: 0,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.electric_car, color: Colors.tealAccent, size: 20),
            SizedBox(width: 6),
            Flexible(
              child: Text(
                'Yaris 混动与 OBD 车况',
                style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // 扫描与连接状态操作区
          ValueListenableBuilder<ObdTelemetry>(
            valueListenable: _obd.telemetryNotifier,
            builder: (context, tel, _) {
              final isConnected = tel.status == ObdConnectionStatus.ready;
              final isBusy = tel.status == ObdConnectionStatus.connecting ||
                  tel.status == ObdConnectionStatus.initializing ||
                  tel.status == ObdConnectionStatus.scanning;

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _getStatusColor(tel.status).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _getStatusColor(tel.status), width: 1),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: _getStatusColor(tel.status),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 130),
                          child: Text(
                            tel.statusMessage ?? tel.status.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: _getStatusColor(tel.status),
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!isConnected)
                    ValueListenableBuilder<bool>(
                      valueListenable: _obd.isScanningNotifier,
                      builder: (ctx, isScanning, _) {
                        return ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.blueAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          ),
                          icon: Icon(
                            isScanning ? Icons.sync : Icons.bluetooth_searching,
                            size: 16,
                          ),
                          label: Text(
                            isScanning ? '扫描中...' : '扫描 OBD',
                            style: const TextStyle(fontSize: 12),
                          ),
                          onPressed: isBusy
                              ? null
                              : () async {
                                  await _obd.startScan();
                                  if (mounted) {
                                    _showDeviceSelectDialog(_obd.scanResultsNotifier.value);
                                  }
                                },
                        );
                      },
                    )
                  else
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.shade900,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      ),
                      icon: const Icon(Icons.link_off, size: 16),
                      label: const Text('断开', style: TextStyle(fontSize: 12)),
                      onPressed: () => _obd.disconnect(),
                    ),
                  if (isConnected) ...[
                    const SizedBox(width: 6),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF162534),
                        foregroundColor: Colors.lightBlueAccent,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: const BorderSide(color: Colors.lightBlueAccent, width: 1),
                        ),
                      ),
                      icon: const Icon(Icons.speed, size: 15, color: Colors.lightBlueAccent),
                      label: const Text('读标准PID', style: TextStyle(fontSize: 11)),
                      onPressed: () => _obd.verifyStandardPidsExplicitly(),
                    ),
                  ],
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1E3A2F),
                      foregroundColor: Colors.tealAccent,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                        side: const BorderSide(color: Colors.tealAccent, width: 1),
                      ),
                    ),
                    icon: const Icon(Icons.manage_search, size: 16, color: Colors.tealAccent),
                    label: const Text('全车深度扫描',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    onPressed: () => ObdDeepScanDialog.show(context),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: '指令调试控制台',
                    icon: Icon(
                      _showTerminal ? Icons.terminal : Icons.terminal_outlined,
                      color: _showTerminal ? Colors.amberAccent : Colors.white70,
                      size: 22,
                    ),
                    onPressed: () {
                      setState(() => _showTerminal = !_showTerminal);
                    },
                  ),
                  const SizedBox(width: 6),
                ],
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ValueListenableBuilder<ObdTelemetry>(
          valueListenable: _obd.telemetryNotifier,
          builder: (context, tel, _) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 左侧主要仪表与混动大屏数据
                Expanded(
                  flex: _showTerminal ? 3 : 5,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. 混动核心三电卡片 (SoC, 电池电压/电流/功率)
                        _buildHybridBatteryCard(tel),
                        const SizedBox(height: 10),

                        // 2. 发动机与动力流卡片 (速度, 转速, 水温, 油温)
                        _buildEngineAndPowerCard(tel),
                        const SizedBox(height: 10),

                        // 3. 升压母线、逆变器与整车小电瓶卡片
                        _buildInverterAndAuxCard(tel),
                      ],
                    ),
                  ),
                ),

                // 右侧可折叠指令调试控制台
                if (_showTerminal)
                  Expanded(
                    flex: 2,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Color(0xFF14171E),
                        border: Border(left: BorderSide(color: Colors.white12)),
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            color: const Color(0xFF1B202B),
                            child: const Row(
                              children: [
                                Icon(Icons.code, color: Colors.amberAccent, size: 16),
                                SizedBox(width: 6),
                                Text(
                                  'ELM327 / UDS 实时通信终端',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // 快捷指令按钮栏 (以标准只读为主)
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _buildQuickBtn('0100', 'CAN探针'),
                              _buildQuickBtn('010D', '车速'),
                              _buildQuickBtn('010C', '转速'),
                              _buildQuickBtn('0105', '水温'),
                              _buildQuickBtn('ATRV', '12V电压'),
                              _buildQuickBtn('ATI', '芯片信息'),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            child: Row(
                              children: [
                                ValueListenableBuilder<bool>(
                                  valueListenable: _obd.enableProprietaryPollingNotifier,
                                  builder: (ctx, enabled, _) {
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Checkbox(
                                          value: enabled,
                                          visualDensity: VisualDensity.compact,
                                          activeColor: Colors.amberAccent,
                                          onChanged: (val) {
                                            if (val == true) {
                                              _showEnableProprietaryWarning(ctx);
                                            } else {
                                              _obd.setProprietaryPolling(false);
                                            }
                                          },
                                        ),
                                        const Text(
                                          '启用私有PID探测 (21C3未经验证)',
                                          style: TextStyle(color: Colors.amberAccent, fontSize: 10),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                          const Divider(color: Colors.white12, height: 1),
                          // 滚动终端日志
                          Expanded(
                            child: ValueListenableBuilder<List<String>>(
                              valueListenable: _obd.debugLogNotifier,
                              builder: (ctx, logs, _) {
                                return ListView.builder(
                                  controller: _logScrollController,
                                  padding: const EdgeInsets.all(8),
                                  itemCount: logs.length,
                                  itemBuilder: (c, i) => Text(
                                    logs[i],
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 10.5,
                                      color: logs[i].contains('❌')
                                          ? Colors.redAccent
                                          : (logs[i].contains('➡️')
                                              ? Colors.lightBlueAccent
                                              : (logs[i].contains('⬅️')
                                                  ? Colors.greenAccent
                                                  : Colors.white70)),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          // 手动指令输入栏
                          Padding(
                            padding: const EdgeInsets.all(6.0),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _customCmdController,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: '输入 AT/OBD 指令 (如 0100)...',
                                      hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
                                      filled: true,
                                      fillColor: Colors.black38,
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                    ),
                                    onSubmitted: (val) {
                                      if (val.trim().isNotEmpty) {
                                        _sendQuickCommand(val.trim());
                                        _customCmdController.clear();
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 6),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.amberAccent.shade700,
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  ),
                                  onPressed: () {
                                    final val = _customCmdController.text.trim();
                                    if (val.isNotEmpty) {
                                      _sendQuickCommand(val);
                                      _customCmdController.clear();
                                    }
                                  },
                                  child: const Text('发送', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildQuickBtn(String cmd, String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: () => _sendQuickCommand(cmd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.blueGrey.shade900,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            '$cmd ($label)',
            style: const TextStyle(color: Colors.white, fontSize: 10),
          ),
        ),
      ),
    );
  }

  Color _getStatusColor(ObdConnectionStatus s) {
    switch (s) {
      case ObdConnectionStatus.ready:
        return Colors.greenAccent;
      case ObdConnectionStatus.scanning:
      case ObdConnectionStatus.connecting:
      case ObdConnectionStatus.initializing:
        return Colors.amberAccent;
      case ObdConnectionStatus.error:
        return Colors.redAccent;
      case ObdConnectionStatus.disconnected:
        return Colors.grey;
    }
  }

  void _showEnableProprietaryWarning(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222B),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amberAccent, size: 20),
            SizedBox(width: 8),
            Text('试验性私有 PID 探测确认', style: TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
        content: const Text(
          '安全提示：\n\n21C3 / 21C4 等私有指令未经当前实车通信验证。\n\n盲测非标准 UDS 指令可能返回异常数据或引起仪表提示。默认已严格关闭。\n\n是否仍要显式开启私有探测？',
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消 (推荐保持关闭)'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amber.shade900),
            onPressed: () {
              Navigator.pop(ctx);
              _obd.setProprietaryPolling(true);
            },
            child: const Text('确认开启探测', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // 1. 混动电池高压核心视图
  Widget _buildHybridBatteryCard(ObdTelemetry tel) {
    final soc = tel.batterySoc;
    final socColor = (soc ?? 0) > 60
        ? Colors.greenAccent
        : ((soc ?? 0) > 30 ? Colors.tealAccent : Colors.orangeAccent);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B202B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.battery_charging_full, color: Colors.tealAccent, size: 18),
                  SizedBox(width: 6),
                  Text(
                    '动力主电池 (4.3Ah 锂电池组 / 1NM 电驱)',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              ValueListenableBuilder<bool>(
                valueListenable: _obd.enableProprietaryPollingNotifier,
                builder: (ctx, enabled, _) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (enabled ? Colors.orange : Colors.grey).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: (enabled ? Colors.orangeAccent : Colors.white30),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      enabled ? '⚠️ 私有探测开启 (未经验证)' : '私有协议未验证 (默认关闭保护车辆)',
                      style: TextStyle(
                        color: enabled ? Colors.orangeAccent : Colors.white60,
                        fontSize: 9.5,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              // 大号 SoC 电池百分比卡片
              Container(
                width: 140,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: socColor.withValues(alpha: 0.4)),
                ),
                child: Column(
                  children: [
                    const Text('动力电池 SoC', style: TextStyle(color: Colors.white60, fontSize: 11)),
                    const SizedBox(height: 4),
                    Text(
                      soc != null ? '${soc.toStringAsFixed(1)}%' : '--',
                      style: TextStyle(
                        color: socColor,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: soc != null ? (soc / 100.0).clamp(0.0, 1.0) : 0,
                      backgroundColor: Colors.white12,
                      valueColor: AlwaysStoppedAnimation<Color>(socColor),
                      minHeight: 6,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // 电池电压、电流、功率矩阵
              Expanded(
                child: Row(
                  children: [
                    _buildMetricItem(
                      label: '电池总电压',
                      value: tel.batteryVoltage != null
                          ? '${tel.batteryVoltage!.toStringAsFixed(1)} V'
                          : '--',
                      icon: Icons.bolt,
                      color: Colors.amberAccent,
                    ),
                    _buildMetricItem(
                      label: '充放实时电流',
                      value: tel.batteryCurrent != null
                          ? '${tel.batteryCurrent! > 0 ? "+" : ""}${tel.batteryCurrent!.toStringAsFixed(1)} A'
                          : '--',
                      icon: Icons.swap_horiz,
                      color: (tel.batteryCurrent ?? 0) < 0
                          ? Colors.orangeAccent
                          : Colors.greenAccent,
                      subtext: (tel.batteryCurrent ?? 0) < 0 ? '放电工况' : '能量回充',
                    ),
                    _buildMetricItem(
                      label: '电池输出功率',
                      value: tel.batteryPowerKw != null
                          ? '${tel.batteryPowerKw!.toStringAsFixed(2)} kW'
                          : '--',
                      icon: Icons.electric_meter,
                      color: Colors.cyanAccent,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (tel.cellDeltaVoltage != null || tel.batteryTemperatures.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (tel.cellDeltaVoltage != null)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Text(
                        '电芯压差: ${(tel.cellDeltaVoltage! * 1000).toInt()} mV (${tel.minCellVoltage?.toStringAsFixed(2)}V ~ ${tel.maxCellVoltage?.toStringAsFixed(2)}V)',
                        style: const TextStyle(color: Colors.tealAccent, fontSize: 10.5),
                      ),
                    ),
                  ),
                if (tel.batteryTemperatures.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Text(
                      '电池包温感: ${tel.batteryTemperatures.map((t) => "${t.toInt()}°C").join(" / ")}',
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 10.5),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  // 2. 发动机与车速动力工况卡片
  Widget _buildEngineAndPowerCard(ObdTelemetry tel) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B202B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.speed, color: Colors.blueAccent, size: 18),
                  SizedBox(width: 6),
                  Text(
                    '发动机与车辆动力学 (M15A-FXE 1.5L 直列3缸)',
                    style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              if (tel.totalOdometerKm != null)
                Text(
                  '总里程: ${tel.totalOdometerKm!.toStringAsFixed(1)} km',
                  style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.bold),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildMetricItem(
                label: '实时车速',
                value: tel.speedKmh != null ? '${tel.speedKmh!.toInt()} km/h' : '--',
                icon: Icons.navigation,
                color: Colors.white,
                isLarge: true,
              ),
              _buildMetricItem(
                label: '发动机转速',
                value: tel.engineRpm != null
                    ? (tel.engineRpm! < 100 ? 'EV 停机' : '${tel.engineRpm!.toInt()} rpm')
                    : '--',
                icon: Icons.rotate_right,
                color: (tel.engineRpm ?? 0) > 100 ? Colors.greenAccent : Colors.tealAccent,
                isLarge: true,
              ),
              _buildMetricItem(
                label: '冷却液水温',
                value: tel.coolantTemp != null ? '${tel.coolantTemp!.toInt()} °C' : '--',
                icon: Icons.thermostat,
                color: (tel.coolantTemp ?? 0) > 100 ? Colors.redAccent : Colors.blueAccent,
              ),
              _buildMetricItem(
                label: '发动机机油温',
                value: tel.engineOilTemp != null ? '${tel.engineOilTemp!.toInt()} °C' : '--',
                icon: Icons.opacity,
                color: Colors.amberAccent,
                subtext: 'PID 015C / TNGA',
              ),
              _buildMetricItem(
                label: '节气门开度',
                value: tel.throttlePosition != null ? '${tel.throttlePosition!.toStringAsFixed(1)}%' : '--',
                icon: Icons.tune,
                color: Colors.lightGreenAccent,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 3. 升压系统、逆变器与电气卡片
  Widget _buildInverterAndAuxCard(ObdTelemetry tel) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B202B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.developer_board, color: Colors.orangeAccent, size: 18),
              SizedBox(width: 6),
              Text(
                '升压母线、逆变器与整车小电瓶 (12V)',
                style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _buildMetricItem(
                label: '升压前电压 VL',
                value: tel.voltageBeforeBoost != null
                    ? '${tel.voltageBeforeBoost!.toStringAsFixed(1)} V'
                    : '--',
                icon: Icons.arrow_downward,
                color: Colors.white70,
              ),
              _buildMetricItem(
                label: '升压母线 VH',
                value: tel.voltageAfterBoost != null
                    ? '${tel.voltageAfterBoost!.toStringAsFixed(1)} V'
                    : '--',
                icon: Icons.arrow_upward,
                color: Colors.deepOrangeAccent,
              ),
              _buildMetricItem(
                label: 'MG1 逆变器温度',
                value: tel.mg1InverterTemp != null ? '${tel.mg1InverterTemp!.toInt()} °C' : '--',
                icon: Icons.device_thermostat,
                color: Colors.tealAccent,
              ),
              _buildMetricItem(
                label: 'MG2 逆变器温度',
                value: tel.mg2InverterTemp != null ? '${tel.mg2InverterTemp!.toInt()} °C' : '--',
                icon: Icons.device_thermostat,
                color: Colors.tealAccent,
              ),
              _buildMetricItem(
                label: '电子水泵转速',
                value: tel.electricWaterPumpRpm != null
                    ? '${tel.electricWaterPumpRpm!.toInt()} rpm'
                    : '--',
                icon: Icons.water,
                color: Colors.lightBlueAccent,
              ),
              _buildMetricItem(
                label: '12V 辅助蓄电池',
                value: tel.aux12vVoltage != null
                    ? '${tel.aux12vVoltage!.toStringAsFixed(2)} V'
                    : '--',
                icon: Icons.car_repair,
                color: (tel.aux12vVoltage ?? 14) < 12.0 ? Colors.redAccent : Colors.greenAccent,
                subtext: (tel.aux12vVoltage ?? 14) < 12.0 ? '低压警告' : '充电正常',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricItem({
    required String label,
    required String value,
    required IconData icon,
    required Color color,
    String? subtext,
    bool isLarge = false,
  }) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(color: Colors.white60, fontSize: 10.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                color: color,
                fontSize: isLarge ? 17 : 14,
                fontWeight: FontWeight.bold,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            if (subtext != null) ...[
              const SizedBox(height: 2),
              Text(
                subtext,
                style: const TextStyle(color: Colors.white38, fontSize: 9.5),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DeviceItem {
  final BluetoothDevice device;
  final String name;
  final String subtitle;
  final bool isBonded;

  const _DeviceItem({
    required this.device,
    required this.name,
    required this.subtitle,
    required this.isBonded,
  });
}
