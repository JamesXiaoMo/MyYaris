import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/obd_telemetry.dart';
import '../models/obd_deep_scan_result.dart';

class CarObdService {
  static final CarObdService _instance = CarObdService._internal();
  factory CarObdService() => _instance;
  CarObdService._internal();

  static const String _prefLastDeviceAddress = 'obd_last_device_address';
  static const String _prefLastDeviceName = 'obd_last_device_name';

  // --- 响应式状态通知 ---
  final ValueNotifier<ObdTelemetry> telemetryNotifier =
      ValueNotifier<ObdTelemetry>(const ObdTelemetry());
  final ValueNotifier<List<ScanResult>> scanResultsNotifier =
      ValueNotifier<List<ScanResult>>([]);
  final ValueNotifier<bool> isScanningNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> debugLogNotifier =
      ValueNotifier<List<String>>([]);
  final ValueNotifier<bool> isDeepScanningNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<ObdDeepScanReport?> lastDeepScanReportNotifier =
      ValueNotifier<ObdDeepScanReport?>(null);

  /// 车辆标准 CAN 总线是否已有效响应 (例如 PID 0100 返回 4100)
  bool canBusReady = false;
  final ValueNotifier<bool> canBusReadyNotifier = ValueNotifier<bool>(false);

  /// 是否开启未验证的丰田私有协议轮询 (Mode 21/22/ATSH7E2 等)
  /// 严格默认关闭！只有用户显式确认启用时才会尝试
  bool enableProprietaryPolling = false;
  final ValueNotifier<bool> enableProprietaryPollingNotifier =
      ValueNotifier<bool>(false);

  /// 是否开启标准 OBD (Mode 01) 周期轮询 (车速/转速/水温)
  /// 需在确认 PID 0100 有效响应后开启
  bool enableStandardPolling = false;
  final ValueNotifier<bool> enableStandardPollingNotifier =
      ValueNotifier<bool>(false);

  bool _isDeepScanning = false;
  bool _cancelDeepScanRequested = false;

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  final StringBuffer _rxBuffer = StringBuffer();
  Completer<String>? _cmdCompleter;
  Completer<void>? _cmdQueue;
  Timer? _pollingTimer;
  bool _isPollingBusy = false;
  int _pollCycleCount = 0;

  // --- 公共属性 ---
  ObdTelemetry get currentTelemetry => telemetryNotifier.value;
  bool get isConnected =>
      telemetryNotifier.value.status == ObdConnectionStatus.ready;
  String? get connectedDeviceName => _connectedDevice?.platformName;

  void log(String message) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final entry = '[$timestamp] $message';
    final current = List<String>.from(debugLogNotifier.value);
    if (current.length > 150) {
      current.removeAt(0);
    }
    current.add(entry);
    debugLogNotifier.value = current;
    debugPrint('[CarObdService] $message');
  }

  // --- 1. 扫描与设备发现 ---
  Future<void> startScan({Duration timeout = const Duration(seconds: 8)}) async {
    try {
      if (await FlutterBluePlus.isSupported == false) {
        log('❌ 当前系统不支持 Bluetooth LE');
        _updateStatus(ObdConnectionStatus.error, message: '设备不支持 BLE');
        return;
      }

      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) {
        log('⚠️ 蓝牙未开启，尝试唤醒或请在系统设置中打开蓝牙');
        _updateStatus(ObdConnectionStatus.error, message: '蓝牙未开启');
        return;
      }

      isScanningNotifier.value = true;
      scanResultsNotifier.value = [];
      _updateStatus(ObdConnectionStatus.scanning, message: '正在扫描周边 OBD 蓝牙设备...');
      log('🔍 开始 BLE 扫描...');

      _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) {
        // 过滤并优先呈现 OBD、Veepeak、CarScanner、BLE 相关设备
        scanResultsNotifier.value = results;
      });

      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((val) => val == false).first;
    } catch (e) {
      log('❌ 扫描发生异常: $e');
      _updateStatus(ObdConnectionStatus.error, message: '扫描异常: $e');
    } finally {
      isScanningNotifier.value = false;
      if (telemetryNotifier.value.status == ObdConnectionStatus.scanning) {
        _updateStatus(ObdConnectionStatus.disconnected, message: '扫描已结束');
      }
    }
  }

  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
      isScanningNotifier.value = false;
    } catch (e) {
      log('停止扫描异常: $e');
    }
  }

  // --- 2. 设备连接与串口 GATT 服务协商 ---
  Future<bool> connect(BluetoothDevice device) async {
    await stopScan();
    await disconnect();

    _connectedDevice = device;
    final deviceName = device.platformName.isNotEmpty
        ? device.platformName
        : device.remoteId.str;

    _updateStatus(
      ObdConnectionStatus.connecting,
      message: '正在连接 $deviceName...',
      deviceName: deviceName,
      deviceId: device.remoteId.str,
    );
    log('🔗 尝试连接 BLE 设备: $deviceName (${device.remoteId.str})');

    try {
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
        autoConnect: false,
      );

      _connectionStateSubscription = device.connectionState.listen((state) {
        log('📶 蓝牙链路状态变动: $state');
        if (state == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      // 调整 MTU 加速多帧报文传输
      try {
        if (!kIsWeb) {
          await device.requestMtu(247);
        }
      } catch (e) {
        log('MTU 协商忽略: $e');
      }

      log('🔎 正在发现 GATT 服务与串口特征值...');
      final services = await device.discoverServices();
      final channel = _resolveObdGattChannel(services);

      if (channel == null) {
        log('❌ 未能在该设备中找到兼容的串口 GATT 读写通道');
        await disconnect();
        _updateStatus(ObdConnectionStatus.error, message: '未找到 OBD 串口特征值');
        return false;
      }

      _writeCharacteristic = channel.writeCharacteristic;
      final notifyChar = channel.notifyCharacteristic;

      log('🎯 锁定 OBD 通信通道 [${channel.profileName}]');
      log('   🔹 服务: ${channel.service.uuid.str128}');
      log('   🔸 TX写特征: ${channel.writeCharacteristic.uuid.str128}');
      log('   🔸 RX读特征: ${channel.notifyCharacteristic.uuid.str128}');

      // 开启数据下行监听
      await notifyChar.setNotifyValue(true);
      _notifySubscription = notifyChar.onValueReceived.listen(_onDataReceived);

      _updateStatus(ObdConnectionStatus.initializing, message: '正在初始化 ELM327 适配器...');
      log('⚙️ 开始 ELM327 指令握手初始化...');

      final initSuccess = await _initializeElm327();
      if (!initSuccess) {
        log('❌ ELM327 初始化握手失败，断开连接');
        await disconnect();
        _updateStatus(ObdConnectionStatus.error, message: 'ELM327 初始化无应答');
        return false;
      }

      // 保存本次成功连接的设备，以便后续自动重连
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefLastDeviceAddress, device.remoteId.str);
      await prefs.setString(_prefLastDeviceName, deviceName);

      final statusMsg = canBusReady
          ? 'OBD 适配器与车辆标准 CAN 已联机'
          : 'OBD 适配器已握手 (车辆 ECU 未响应/NO DATA)';

      _updateStatus(
        ObdConnectionStatus.ready,
        message: statusMsg,
        deviceName: deviceName,
        deviceId: device.remoteId.str,
      );
      if (canBusReady) {
        log('🎉 适配器与车辆 CAN 总线联机完成');
      } else {
        log('ℹ️ 适配器已握手；车辆 ECU 尚未响应，未执行私有与混动探测');
      }

      _startPolling();
      return true;
    } catch (e) {
      log('❌ 连接失败: $e');
      await disconnect();
      final isTimeout = e.toString().contains('Timed out');
      final msg = isTimeout ? '连接超时 (模块可能休眠，请开启车辆电源唤醒)' : '连接失败: $e';
      _updateStatus(ObdConnectionStatus.error, message: msg);
      return false;
    }
  }

  // --- 3. ELM327 AT 指令集初始化流程 ---
  Future<bool> _initializeElm327() async {
    try {
      // 1. 复位适配器
      var resp = await sendRawCommand('ATZ', timeout: const Duration(seconds: 2));
      log('ATZ 应答: $resp');
      // 给 ELM327 芯片 350ms 重新稳定内部波特率与缓冲区
      await Future.delayed(const Duration(milliseconds: 350));

      // 2. 关闭回显与换行
      final ate0Resp = await sendRawCommand('ATE0');
      log('ATE0 (关闭回显) 应答: $ate0Resp');
      await sendRawCommand('ATL0');

      // 3. 读取适配器标识 (只读识别)
      final ati = await sendRawCommand('ATI');
      log('ATI (固件识别) 应答: $ati');

      // 4. 读取 12V 蓄电池引脚电压 (引脚16独立 ADC 测量，不依赖车辆 ECU 就绪)
      final atrv = await sendRawCommand('ATRV');
      log('ATRV (12V 电瓶电压) 应答: $atrv');
      final battV = _parseAtRv(atrv);
      if (battV != null) {
        _updateTelemetry((t) => t.copyWith(
              aux12vVoltage: battV,
            ));
      }

      // 5. 关闭空格加速传输
      await sendRawCommand('ATS0');

      // 6. 关闭多余报头 (标准 PID 模式)
      await sendRawCommand('ATH0');

      // 7. 自适应超时
      await sendRawCommand('ATAT1');

      // 8. 锁定丰田 CAN 协议: ISO 15765-4 CAN 11-bit 500k
      resp = await sendRawCommand('ATSP6');
      log('ATSP6 (锁定 CAN 11-bit 500k) 应答: $resp');

      // 9. 测试读取支持的 PID 0100 确认车辆 CAN 就绪
      resp = await sendRawCommand('0100', timeout: const Duration(seconds: 3));
      log('0100 测试应答: $resp');

      if (resp.contains('4100') || resp.contains('41 00')) {
        canBusReady = true;
        canBusReadyNotifier.value = true;
        log('🎉 车辆 ECU 已成功响应 PID 0100，标准 CAN 总线已联机');
      } else {
        canBusReady = false;
        canBusReadyNotifier.value = false;
        log('ℹ️ 车辆 ECU 未响应 PID 0100 (应答: $resp)，适配器保持监听，等待车辆通电');
      }

      // 只要适配器能响应 AT 指令 (ATE0/ATI/ATRV 正常返回非 ERROR)，即认定适配器链路正常
      final adapterOk = (ate0Resp.isNotEmpty && !ate0Resp.startsWith('ERROR')) ||
          (ati.isNotEmpty && !ati.startsWith('ERROR')) ||
          (atrv.isNotEmpty && !atrv.startsWith('ERROR'));
      return adapterOk;
    } catch (e) {
      log('初始化指令异常: $e');
      return false;
    }
  }

  // --- 4. 周期调度与分级轮询引擎 ---
  void _startPolling() {
    _pollingTimer?.cancel();
    _pollCycleCount = 0;
    // 基础安全轮询周期 2.5 秒
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 2500), (timer) {
      _pollCycle();
    });
  }

  Future<void> _pollCycle() async {
    if (_isPollingBusy || !isConnected) return;
    _isPollingBusy = true;
    _pollCycleCount++;

    try {
      // 基础安全轮询: 仅读取适配器 12V 蓄电池引脚电压 (引脚16独立 ADC 测量，不向车辆发送任何 CAN 诊断报文)
      final atrv = await sendRawCommand('ATRV');
      final battV = _parseAtRv(atrv);
      if (battV != null) {
        _updateTelemetry((t) => t.copyWith(
              aux12vVoltage: battV,
              lastUpdated: DateTime.now(),
            ));
      }

      // 仅当车辆 CAN 总线已明确就绪 (PID 0100 有效响应) 且用户显式启用标准轮询时，才读取标准 Mode 01 PID
      if (canBusReady && enableStandardPolling) {
        await _queryStandardEngineTier1();
      }

      // 未经验证的私有 Mode 21/22 指令严格默认完全关闭！绝不在普通连接中自动发送
      if (enableProprietaryPolling) {
        if (_pollCycleCount % 2 == 0) {
          await _queryToyotaHybridTier2();
        }
        if (_pollCycleCount % 5 == 0) {
          await _queryToyotaEngineAndAuxTier3();
        }
        if (_pollCycleCount % 25 == 0) {
          await _queryLowFrequencyTier4();
        }
      }
    } catch (e) {
      log('轮询周期发生异常: $e');
    } finally {
      _isPollingBusy = false;
    }
  }

  /// 显式单次验证标准 Mode 01 PID (0100, 010D, 010C, 0105)
  Future<void> verifyStandardPidsExplicitly() async {
    if (!isConnected) {
      log('⚠️ 适配器未连接，无法执行标准 PID 验证');
      return;
    }
    log('🔬 [显式验证] 正在发送标准 OBD 0100 指令探测车辆 CAN 总线...');
    final resp0100 = await sendRawCommand('0100');
    log('🔬 [显式验证] 0100 应答: $resp0100');

    if (resp0100.contains('4100') || resp0100.contains('41 00')) {
      canBusReady = true;
      canBusReadyNotifier.value = true;
      log('✅ 车辆 ECU 确认支持 Mode 01 标准协议，开始采集单次标准车况...');
      await _queryStandardEngineTier1();
      log('✅ 标准车况 (车速/转速/水温) 读取完成');
    } else {
      canBusReady = false;
      canBusReadyNotifier.value = false;
      log('❌ 车辆 ECU 未应答标准 0100 (应答: $resp0100)，请确保车辆电源处于 ON 档');
    }
  }

  void setProprietaryPolling(bool enable) {
    enableProprietaryPolling = enable;
    enableProprietaryPollingNotifier.value = enable;
    if (enable) {
      log('⚠️ 用户已显式启用试验性私有 PID 轮询 (Mode 21/22，解码未经验证)');
    } else {
      log('🔒 已关闭试验性私有 PID 轮询');
    }
  }

  void setStandardPolling(bool enable) {
    enableStandardPolling = enable;
    enableStandardPollingNotifier.value = enable;
    if (enable) {
      log('🟢 用户已显式启用标准 Mode 01 周期轮询');
    } else {
      log('⚪ 已关闭标准 Mode 01 周期轮询');
    }
  }

  // Tier 1: 标准 OBD 010D (车速), 010C (转速), 0105 (水温)
  Future<void> _queryStandardEngineTier1() async {
    // 确保使用标准功能寻址
    // 1. 车速 (010D)
    final speedResp = await sendRawCommand('010D');
    final speed = _parseStandardSpeed(speedResp);

    // 2. 转速 (010C)
    final rpmResp = await sendRawCommand('010C');
    final rpm = _parseStandardRpm(rpmResp);

    // 3. 水温 (0105)
    final coolantResp = await sendRawCommand('0105');
    final coolant = _parseStandardTemp(coolantResp);

    _updateTelemetry((t) => t.copyWith(
          speedKmh: speed ?? t.speedKmh,
          engineRpm: rpm ?? t.engineRpm,
          coolantTemp: coolant ?? t.coolantTemp,
          lastUpdated: DateTime.now(),
        ));
  }

  // Tier 2: 丰田混动 0x7E2 / 21C3 (SoC, 电池总压, 充放电流, 逆变器温度)
  // 及 21C4 (升压前VL, 升压后VH)
  Future<void> _queryToyotaHybridTier2() async {
    // 切换至混动 ECU 寻址
    await sendRawCommand('ATSH7E2');

    // 1. 发送 21C3 (混动动力系统核心遥测)
    final c3Resp = await sendRawCommand('21C3');
    _parseToyota21C3(c3Resp);

    // 2. 发送 21C4 (变压升压与扭矩)
    final c4Resp = await sendRawCommand('21C4');
    _parseToyota21C4(c4Resp);

    // 切回标准广播报头
    await sendRawCommand('ATSH7DF');
  }

  // Tier 3: 辅助 12V 电池、机油温度、节气门与进气
  Future<void> _queryToyotaEngineAndAuxTier3() async {
    // 1. 读取 12V 电池电压 (AT RV 或 0142)
    final rvResp = await sendRawCommand('ATRV');
    final auxV = _parseAtRv(rvResp);

    // 2. 读取节气门开度 (0111) 与 发动机负荷 (0104)
    final thResp = await sendRawCommand('0111');
    final throttle = _parsePercent(thResp);

    final loadResp = await sendRawCommand('0104');
    final load = _parsePercent(loadResp);

    // 3. 进气温度 (010F)
    final iatResp = await sendRawCommand('010F');
    final iat = _parseStandardTemp(iatResp);

    _updateTelemetry((t) => t.copyWith(
          aux12vVoltage: auxV ?? t.aux12vVoltage,
          throttlePosition: throttle ?? t.throttlePosition,
          engineLoad: load ?? t.engineLoad,
          intakeAirTemp: iat ?? t.intakeAirTemp,
        ));
  }

  // Tier 4: 里程 (ODO) 与 剩余油位
  Future<void> _queryLowFrequencyTier4() async {
    // 切换至发动机 ECM 0x7E0
    await sendRawCommand('ATSH7E0');

    // 发动机 ECM 机油温度与专用传感器 (21CE 或 221234)
    final ecmResp = await sendRawCommand('21CE');
    _parseToyotaEcm21CE(ecmResp);

    // 切回标准广播报头
    await sendRawCommand('ATSH7DF');
  }

  // --- 5. 数据解码器 (Parser 实现) ---

  // 010D: 41 0D XX -> XX (km/h)
  double? _parseStandardSpeed(String resp) {
    final clean = _cleanHex(resp);
    final idx = clean.indexOf('410D');
    if (idx != -1 && clean.length >= idx + 6) {
      final hexA = clean.substring(idx + 4, idx + 6);
      return int.tryParse(hexA, radix: 16)?.toDouble();
    }
    return null;
  }

  // 010C: 41 0C AA BB -> ((AA*256)+BB)/4
  double? _parseStandardRpm(String resp) {
    final clean = _cleanHex(resp);
    final idx = clean.indexOf('410C');
    if (idx != -1 && clean.length >= idx + 8) {
      final hexA = clean.substring(idx + 4, idx + 6);
      final hexB = clean.substring(idx + 6, idx + 8);
      final valA = int.tryParse(hexA, radix: 16);
      final valB = int.tryParse(hexB, radix: 16);
      if (valA != null && valB != null) {
        return ((valA * 256) + valB) / 4.0;
      }
    }
    return null;
  }

  // 0105 / 010F / 0146: 41 XX YY -> YY - 40
  double? _parseStandardTemp(String resp) {
    final clean = _cleanHex(resp);
    final match = RegExp(r'41(05|0F|46)([0-9A-F]{2})').firstMatch(clean);
    if (match != null) {
      final val = int.tryParse(match.group(2)!, radix: 16);
      if (val != null) return val - 40.0;
    }
    if (clean.length >= 6) {
      final hexVal = clean.substring(clean.length - 2);
      final val = int.tryParse(hexVal, radix: 16);
      if (val != null) return val - 40.0;
    }
    return null;
  }

  // 0111 / 0104 / 012F: (XX * 100) / 255
  double? _parsePercent(String resp) {
    final clean = _cleanHex(resp);
    final match = RegExp(r'41(11|04|2F)([0-9A-F]{2})').firstMatch(clean);
    if (match != null) {
      final val = int.tryParse(match.group(2)!, radix: 16);
      if (val != null) return (val * 100.0) / 255.0;
    }
    if (clean.length >= 6) {
      final hexVal = clean.substring(clean.length - 2);
      final val = int.tryParse(hexVal, radix: 16);
      if (val != null) return (val * 100.0) / 255.0;
    }
    return null;
  }

  // AT RV: 例如 "14.1V"
  double? _parseAtRv(String resp) {
    final match = RegExp(r'([0-9]+\.?[0-9]*)\s*V').firstMatch(resp);
    if (match != null) {
      return double.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  // 丰田混动 21C3 解码:
  // 响应格式典型以 61 C3 开头的一串 HEX 字节:
  // Byte 18 (S): 动力电池 SoC: 0.392 * S (范围 0~100%)
  // Byte 24 (Y): MG1 逆变器温度: Y - 50 (°C)
  // Byte 25 (Z): MG2 逆变器温度: Z - 50 (°C)
  // Byte 28 (AC): 动力电池总压 VB: 2 * AC (V)
  // Byte 30 (AE): 动力电池电流 IB: 2 * AE - 256 (A, 负放正充)
  void _parseToyota21C3(String resp) {
    final bytes = _extractPayloadBytes(resp, '61C3');
    if (bytes == null || bytes.length < 20) return;

    try {
      double? soc;
      double? vb;
      double? ib;
      double? mg1T;
      double? mg2T;

      // SoC (位置在索引 18)
      if (bytes.length > 18) {
        soc = (bytes[18] * 100.0) / 255.0; // 与 0.392*S 等效
      }

      // MG1 & MG2 逆变器温度 (索引 24, 25)
      if (bytes.length > 25) {
        mg1T = (bytes[24] - 50).toDouble();
        mg2T = (bytes[25] - 50).toDouble();
      }

      // 电池电压与电流 (索引 28, 30)
      if (bytes.length > 30) {
        vb = (bytes[28] * 2).toDouble();
        ib = (bytes[30] * 2 - 256).toDouble();
      }

      double? powerKw;
      if (vb != null && ib != null) {
        powerKw = (vb * ib) / 1000.0;
      }

      _updateTelemetry((t) => t.copyWith(
            batterySoc: soc ?? t.batterySoc,
            batteryVoltage: vb ?? t.batteryVoltage,
            batteryCurrent: ib ?? t.batteryCurrent,
            batteryPowerKw: powerKw ?? t.batteryPowerKw,
            mg1InverterTemp: mg1T ?? t.mg1InverterTemp,
            mg2InverterTemp: mg2T ?? t.mg2InverterTemp,
          ));
    } catch (e) {
      log('解析 21C3 失败: $e');
    }
  }

  // 丰田混动 21C4 解码:
  // 响应以 61 C4 开头:
  // Byte 3 (D): VL 升压前电压: 2 * D (V)
  // Byte 4 (E): VH 升压后电压: 2 * E (V)
  void _parseToyota21C4(String resp) {
    final bytes = _extractPayloadBytes(resp, '61C4');
    if (bytes == null || bytes.length < 6) return;

    try {
      final vl = (bytes[3] * 2).toDouble();
      final vh = (bytes[4] * 2).toDouble();

      _updateTelemetry((t) => t.copyWith(
            voltageBeforeBoost: vl,
            voltageAfterBoost: vh,
          ));
    } catch (e) {
      log('解析 21C4 失败: $e');
    }
  }

  // 丰田 ECM 21CE 解码 (机油温度等)
  void _parseToyotaEcm21CE(String resp) {
    final bytes = _extractPayloadBytes(resp, '61CE');
    if (bytes == null || bytes.isEmpty) return;

    try {
      // 常见机油温度位于前序字节 Byte 0 或 1: Val - 40
      final oilTemp = (bytes[0] - 40).toDouble();
      _updateTelemetry((t) => t.copyWith(engineOilTemp: oilTemp));
    } catch (e) {
      log('解析 21CE 失败: $e');
    }
  }

  List<int>? _extractPayloadBytes(String rawResp, String prefixHex) {
    final clean = _cleanHex(rawResp);
    final idx = clean.indexOf(prefixHex);
    if (idx == -1) return null;

    final hexData = clean.substring(idx + prefixHex.length);
    final result = <int>[];
    for (int i = 0; i + 1 < hexData.length; i += 2) {
      final b = int.tryParse(hexData.substring(i, i + 2), radix: 16);
      if (b != null) result.add(b);
    }
    return result;
  }

  String _cleanHex(String raw) {
    return raw
        .replaceAll(RegExp(r'[\r\n\s>:]'), '')
        .toUpperCase();
  }

  // --- 6. 指令发送与串口底层收发 ---
  Future<String> sendRawCommand(
    String command, {
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    while (_cmdQueue != null) {
      try {
        await _cmdQueue!.future;
      } catch (_) {}
    }
    final queueCompleter = Completer<void>();
    _cmdQueue = queueCompleter;

    try {
      return await _sendRawCommandInternal(command, timeout: timeout);
    } finally {
      if (_cmdQueue == queueCompleter) {
        _cmdQueue = null;
      }
      if (!queueCompleter.isCompleted) {
        queueCompleter.complete();
      }
    }
  }

  Future<String> _sendRawCommandInternal(
    String command, {
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final writeChar = _writeCharacteristic;
    if (writeChar == null || _connectedDevice == null) {
      return 'ERROR: DISCONNECTED';
    }

    _rxBuffer.clear();
    _cmdCompleter = Completer<String>();

    final formatted = '${command.trim()}\r';
    final bytes = ascii.encode(formatted);

    final hasWriteNoResp = writeChar.properties.writeWithoutResponse;
    final hasWrite = writeChar.properties.write;
    final useWithoutResponse = hasWriteNoResp;

    try {
      try {
        await writeChar.write(bytes, withoutResponse: useWithoutResponse);
      } catch (e) {
        if (hasWrite && hasWriteNoResp) {
          log('⚠️ 切换写入模式重试: withoutResponse=${!useWithoutResponse}');
          await writeChar.write(bytes, withoutResponse: !useWithoutResponse);
        } else {
          rethrow;
        }
      }

      // 指令间隔安全延时，保护低功耗蓝牙芯片 FIFO
      await Future.delayed(const Duration(milliseconds: 25));

      final response = await _cmdCompleter!.future.timeout(
        timeout,
        onTimeout: () {
          final partial = _rxBuffer.toString();
          log('⏱️ 指令 "$command" 响应超时, 缓冲区内容: "$partial"');
          return partial.isNotEmpty ? partial : 'TIMEOUT';
        },
      );
      return response.trim();
    } catch (e) {
      log('指令 "$command" 发送失败: $e');
      return 'ERROR: $e';
    } finally {
      _cmdCompleter = null;
    }
  }

  void _onDataReceived(List<int> data) {
    if (data.isEmpty) return;
    final text = ascii.decode(data, allowInvalid: true);
    _rxBuffer.write(text);

    // ELM327 完成一次应答后以 '>' 结束
    if (_rxBuffer.toString().contains('>')) {
      final completeResponse = _rxBuffer.toString().replaceAll('>', '').trim();
      if (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
        _cmdCompleter!.complete(completeResponse);
      }
    }
  }

  // --- 7. 连接断开与清理 ---
  void _handleDisconnection() {
    _pollingTimer?.cancel();
    _updateStatus(ObdConnectionStatus.disconnected, message: '蓝牙连接已断开');
    log('🔌 OBD 蓝牙链路已终止');
  }

  Future<void> disconnect() async {
    _pollingTimer?.cancel();
    _notifySubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _writeCharacteristic = null;
    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.disconnect();
      } catch (e) {
        log('断开连接提示: $e');
      }
      _connectedDevice = null;
    }

    canBusReady = false;
    canBusReadyNotifier.value = false;
    _updateStatus(ObdConnectionStatus.disconnected, message: '未连接设备');
  }

  void _updateStatus(
    ObdConnectionStatus status, {
    String? message,
    String? deviceName,
    String? deviceId,
  }) {
    telemetryNotifier.value = telemetryNotifier.value.copyWith(
      status: status,
      statusMessage: message,
      connectedDeviceName: deviceName,
      connectedDeviceId: deviceId,
      lastUpdated: DateTime.now(),
    );
  }

  void _updateTelemetry(ObdTelemetry Function(ObdTelemetry) updater) {
    telemetryNotifier.value = updater(telemetryNotifier.value);
  }

  // --- 8. 全车数据一键深度探测与扫描引擎 (Deep Scan & Export) ---
  bool get isDeepScanning => _isDeepScanning;

  void cancelDeepScan() {
    if (_isDeepScanning) {
      _cancelDeepScanRequested = true;
      log('⚠️ 用户请求终止全车深度扫描');
    }
  }

  Future<ObdDeepScanReport?> runDeepScan({
    void Function(double progress, String status, ObdDiscoveredItem? newItem)?
        onProgress,
  }) async {
    if (!isConnected || _isDeepScanning) return null;
    _isDeepScanning = true;
    _cancelDeepScanRequested = false;
    isDeepScanningNotifier.value = true;

    // 暂停周期性轮询，避免总线串口请求冲突
    _pollingTimer?.cancel();

    final startTime = DateTime.now();
    log('🔬 启动全车深度扫描与数据探索 (Deep Scan)...');

    final discoveredItems = <ObdDiscoveredItem>[];
    final activeEcus = <String>[];
    String protocolName = 'ISO 15765-4 CAN 11-bit 500k';

    try {
      // 1. 读取通信协议
      final dpResp = await sendRawCommand('ATDP');
      if (dpResp.isNotEmpty && !dpResp.contains('ERROR')) {
        protocolName = dpResp;
      }

      // 2. 发现活跃 ECU 节点
      onProgress?.call(0.04, '正在探测全车在线 ECU 电脑节点...', null);
      await sendRawCommand('ATH1'); // 临时开启报头
      final ecuProbeResp =
          await sendRawCommand('0100', timeout: const Duration(seconds: 3));
      await sendRawCommand('ATH0'); // 关闭报头

      final ecuMap = {
        '7E8': 'ECM 发动机控制电脑',
        '7EA': 'HV 混动系统控制电脑',
        '7EB': 'EVB 混动动力电池电脑',
        '7B8': 'Combination Meter 组合仪表',
        '7D8': 'A/C 空调与车身电脑',
        '738': 'EPS 电子助力转向',
        '768': 'TSS 毫米波雷达/主动安全',
      };

      for (final entry in ecuMap.entries) {
        if (ecuProbeResp.contains(entry.key)) {
          activeEcus.add('${entry.key} (${entry.value})');
        }
      }
      if (activeEcus.isEmpty) {
        activeEcus.add('7E8 (ECM 发动机节点)');
        activeEcus.add('7EA (HV 混动系统节点)');
      }
      log('发现活跃 ECU 节点: $activeEcus');

      // 3. 构建全车探测探针列表
      final probeList = _buildProbeList();
      final totalCount = probeList.length;
      int testedCount = 0;
      int supportedCount = 0;

      for (final probe in probeList) {
        if (_cancelDeepScanRequested) {
          log('⚠️ 深度扫描已被用户提前终止');
          break;
        }

        testedCount++;
        final progress = 0.08 + (testedCount / totalCount) * 0.90;
        onProgress?.call(
            progress, '探测 ${probe.category}: ${probe.cmd} (${probe.name})...', null);

        // 切换报头 (若指定特定 ECU)
        if (probe.header != null) {
          await sendRawCommand('ATSH${probe.header}');
        }

        final sw = Stopwatch()..start();
        final rawResp = await sendRawCommand(probe.cmd,
            timeout: const Duration(milliseconds: 1400));
        sw.stop();

        final isSupported = _isResponseValid(rawResp, probe.cmd);
        String? hint;
        if (isSupported) {
          supportedCount++;
          hint = _formatSampleValue(probe.cmd, rawResp);
          log('✅ 发现有效数据 [${probe.header ?? "7DF"}] ${probe.cmd} (${probe.name}): $rawResp ${hint != null ? "-> $hint" : ""}');
        }

        final item = ObdDiscoveredItem(
          category: probe.category,
          header: probe.header ?? '7DF',
          command: probe.cmd,
          name: probe.name,
          rawHexResponse: rawResp,
          decodedHint: hint,
          responseTimeMs: sw.elapsedMilliseconds,
          isSupported: isSupported,
        );
        discoveredItems.add(item);
        onProgress?.call(
            progress, '已测 $testedCount/$totalCount (开放 $supportedCount 项)', item);

        // 微小停顿，避免过密占用 CAN 总线
        await Future.delayed(const Duration(milliseconds: 30));
      }

      // 还原广播报头
      await sendRawCommand('ATSH7DF');
      await sendRawCommand('ATH0');

      final report = ObdDeepScanReport(
        startTime: startTime,
        endTime: DateTime.now(),
        deviceName: connectedDeviceName ?? 'Veepeak OBDCheck BLE+',
        protocolName: protocolName,
        activeEcus: activeEcus,
        items: discoveredItems,
        totalTested: testedCount,
        totalSupported: supportedCount,
      );

      lastDeepScanReportNotifier.value = report;
      log('🎉 深度扫描完成！共测试 $testedCount 项，车辆开放响应 $supportedCount 项');
      return report;
    } catch (e) {
      log('❌ 深度扫描异常: $e');
      return null;
    } finally {
      _isDeepScanning = false;
      _cancelDeepScanRequested = false;
      isDeepScanningNotifier.value = false;
      // 恢复常规轮询
      _startPolling();
    }
  }

  bool _isResponseValid(String raw, String cmd) {
    if (raw.isEmpty ||
        raw.contains('NO DATA') ||
        raw.contains('UNABLE') ||
        raw.contains('ERROR') ||
        raw.contains('TIMEOUT') ||
        raw.contains('7F')) {
      return false;
    }
    final clean = _cleanHex(raw);
    if (clean.length < 4) return false;

    // 针对 Mode 01: 正响应以 41 开头
    if (cmd.startsWith('01') && clean.contains('41')) return true;
    // 针对 Mode 09: 正响应以 49 开头
    if (cmd.startsWith('09') && clean.contains('49')) return true;
    // 针对 Mode 21: 正响应以 61 开头
    if (cmd.startsWith('21') && clean.contains('61')) return true;
    // 针对 Mode 22: 正响应以 62 开头
    if (cmd.startsWith('22') && clean.contains('62')) return true;

    return true;
  }

  String? _formatSampleValue(String cmd, String raw) {
    if (cmd == '010D') {
      final s = _parseStandardSpeed(raw);
      if (s != null) return '${s.toInt()} km/h';
    } else if (cmd == '010C') {
      final r = _parseStandardRpm(raw);
      if (r != null) return '${r.toInt()} rpm';
    } else if (cmd == '0105') {
      final c = _parseStandardTemp(raw);
      if (c != null) return '${c.toInt()} °C (水温)';
    } else if (cmd == '21C3') {
      return '混动核心遥测 (包含电池SoC/总电压/充放电流/逆变器温)';
    } else if (cmd == '21C4') {
      return '升压变压器与扭矩 (包含升压前VL/升压后VH)';
    } else if (cmd == '21CE') {
      return '油温与动力总成高阶参数';
    } else if (cmd == '0111') {
      final p = _parsePercent(raw);
      if (p != null) return '${p.toStringAsFixed(1)}% (节气门)';
    } else if (cmd == '0142') {
      final v = _parseAtRv(raw);
      if (v != null) return '${v.toStringAsFixed(2)} V (12V小电池)';
    } else if (cmd == '0902') {
      return '车辆 VIN 码';
    }
    return null;
  }

  List<_ProbeEntry> _buildProbeList() {
    return const [
      // 1. 标准 OBD-II / JOBD (Mode 01)
      _ProbeEntry('标准OBD', null, '0104', '发动机计算负荷 (Engine Load)'),
      _ProbeEntry('标准OBD', null, '0105', '发动机冷却液温度 (Coolant Temp)'),
      _ProbeEntry('标准OBD', null, '0106', '短期燃油修正 Bank 1 (STFT)'),
      _ProbeEntry('标准OBD', null, '0107', '长期燃油修正 Bank 1 (LTFT)'),
      _ProbeEntry('标准OBD', null, '010A', '燃油压力表压 (Fuel Pressure)'),
      _ProbeEntry('标准OBD', null, '010B', '进气歧管绝对压力 (MAP)'),
      _ProbeEntry('标准OBD', null, '010C', '发动机实际转速 (Engine RPM)'),
      _ProbeEntry('标准OBD', null, '010D', '车辆行驶车速 (Vehicle Speed)'),
      _ProbeEntry('标准OBD', null, '010E', '点火提前角 (Timing Advance)'),
      _ProbeEntry('标准OBD', null, '010F', '进气空气温度 (Intake Air Temp)'),
      _ProbeEntry('标准OBD', null, '0110', '进气空气质量流量 (MAF)'),
      _ProbeEntry('标准OBD', null, '0111', '绝对节气门位置 (Throttle Position)'),
      _ProbeEntry('标准OBD', null, '0112', '二次空气指令状态 (Secondary Air)'),
      _ProbeEntry('标准OBD', null, '0113', '氧传感器布置状态 (O2 Sensors)'),
      _ProbeEntry('标准OBD', null, '0114', '氧传感器 1 电压 (O2 Bank 1 Sensor 1)'),
      _ProbeEntry('标准OBD', null, '0115', '氧传感器 2 电压 (O2 Bank 1 Sensor 2)'),
      _ProbeEntry('标准OBD', null, '011C', 'OBD 认证法规标准 (JOBD / OBD)'),
      _ProbeEntry('标准OBD', null, '011F', '发动机本次启动运行时间 (Run Time)'),
      _ProbeEntry('标准OBD', null, '0121', '故障灯点亮后行驶距离 (Distance with MIL)'),
      _ProbeEntry('标准OBD', null, '012E', '蒸发排放脱附指令 (Evap Purge)'),
      _ProbeEntry('标准OBD', null, '012F', '燃油箱液位输入百分比 (Fuel Level %)'),
      _ProbeEntry('标准OBD', null, '0130', '清码后热车循环次数 (Warm-ups)'),
      _ProbeEntry('标准OBD', null, '0131', '清码后累计行驶距离 (Distance Cleared)'),
      _ProbeEntry('标准OBD', null, '0132', '蒸发系统蒸汽压力 (Evap Vapor Press)'),
      _ProbeEntry('标准OBD', null, '0133', '绝对大气压强 (Barometric Pressure)'),
      _ProbeEntry('标准OBD', null, '0134', '空燃比当量比 (Lambda Equivalence)'),
      _ProbeEntry('标准OBD', null, '013C', '催化转化器温度 1 (Cat Temp Sensor 1)'),
      _ProbeEntry('标准OBD', null, '013D', '催化转化器温度 2 (Cat Temp Sensor 2)'),
      _ProbeEntry('标准OBD', null, '0142', 'ECU 控制模块供电电压 (Module Voltage)'),
      _ProbeEntry('标准OBD', null, '0143', '绝对负荷值 (Absolute Load)'),
      _ProbeEntry('标准OBD', null, '0144', '指令空燃比当量比 (Commanded Equivalence)'),
      _ProbeEntry('标准OBD', null, '0145', '相对节气门位置 (Relative Throttle)'),
      _ProbeEntry('标准OBD', null, '0146', '车外环境空气温度 (Ambient Air Temp)'),
      _ProbeEntry('标准OBD', null, '0147', '绝对节气门位置 B (Throttle Position B)'),
      _ProbeEntry('标准OBD', null, '0149', '油门踏板位置 D (Pedal Position D)'),
      _ProbeEntry('标准OBD', null, '014A', '油门踏板位置 E (Pedal Position E)'),
      _ProbeEntry('标准OBD', null, '014C', '节气门作动器指令 (Throttle Actuator)'),
      _ProbeEntry('标准OBD', null, '015C', '发动机机油温度 (Engine Oil Temp)'),
      _ProbeEntry('标准OBD', null, '015E', '发动机燃油消耗流率 (Fuel Rate L/h)'),
      _ProbeEntry('标准OBD', null, '01A6', '整车仪表累计总里程 (Odometer)'),

      // 2. 车辆与诊断元数据 (Mode 09)
      _ProbeEntry('车辆信息', null, '0902', '车辆识别代号 (VIN)'),
      _ProbeEntry('车辆信息', null, '0904', '标定识别号 (CALID)'),
      _ProbeEntry('车辆信息', null, '0906', '标定验证号 (CVN)'),
      _ProbeEntry('车辆信息', null, '090A', 'ECU 模块名称 (ECU Name)'),

      // 3. 丰田专有混动系统 (Header 0x7E2 / 0x7E3)
      _ProbeEntry('丰田混动', '7E2', '2101', '混动综合状态基础块 (HV Base Data)'),
      _ProbeEntry('丰田混动', '7E2', '2181', '动力电池单体/模组电压 (HV Cell Voltages)'),
      _ProbeEntry('丰田混动', '7E2', '2182', '动力电池单体内阻 (HV Internal Resistance)'),
      _ProbeEntry('丰田混动', '7E2', '2187', '动力电池包 6 点温感 (HV Temperatures)'),
      _ProbeEntry('丰田混动', '7E2', '21C3', '混动核心三电矩阵 (SOC, VB, IB, MG1/MG2)'),
      _ProbeEntry('丰田混动', '7E2', '21C4', '升压变压器与扭矩 (VL, VH, Boost Temp)'),
      _ProbeEntry('丰田混动', '7E2', '21CE', '混动变速箱/电驱桥油温 (Transaxle Oil Temp)'),
      _ProbeEntry('丰田混动', '7E2', '21CF', '双电机转子/定子温度 (Motor Temp)'),
      _ProbeEntry('丰田混动', '7E2', '21D0', '再生制动与刹车踏板力 (Regen Brake Torque)'),
      _ProbeEntry('丰田混动', '7E2', '220101', 'UDS 混动电池包扩充遥测 (Battery Pack Ext)'),
      _ProbeEntry('丰田混动', '7E2', '221024', 'UDS 混动系统功率限值 (Hybrid System Limits)'),
      _ProbeEntry('丰田混动', '7E2', '222006', 'UDS 车辆总里程 (HV Total Odometer)'),
      _ProbeEntry('丰田混动', '7E2', '222884', 'UDS 锂电池寿命与电量 (Battery Pack Life)'),
      _ProbeEntry('丰田混动', '7E2', '22F190', 'UDS 车辆底盘与 VIN 标识'),
      _ProbeEntry('丰田混动', '7E2', '22F187', 'UDS 混动电脑零件号 (Spare Part Number)'),
      _ProbeEntry('丰田混动', '7E2', '22F189', 'UDS 混动固件版本号 (ECU Software Version)'),

      // 4. 丰田专出发动机 ECM (Header 0x7E0)
      _ProbeEntry('发动机ECM', '7E0', '2101', '发动机 ECM 综合遥测块 (Engine Pack)'),
      _ProbeEntry('发动机ECM', '7E0', '21CE', '机油温度与机油压力 (Oil Temp & Pressure)'),
      _ProbeEntry('发动机ECM', '7E0', '21D4', '电子冷却水泵目标/实际转速 (Water Pump RPM)'),
      _ProbeEntry('发动机ECM', '7E0', '21D5', '进气电驱可变凸轮 VVT-iE 角度 (VVT-iE Angle)'),
      _ProbeEntry('发动机ECM', '7E0', '21D6', '排气凸轮轴 VVT 角度 (Exhaust VVT Angle)'),
      _ProbeEntry('发动机ECM', '7E0', '21D8', '燃油喷油嘴喷射脉宽 (Injector Pulse Width)'),
      _ProbeEntry('发动机ECM', '7E0', '221234', 'ECM 专有复合传感器块 (Extended Sensors)'),
      _ProbeEntry('发动机ECM', '7E0', '222006', 'ECM 记录总里程 (ECM Total Odometer)'),
      _ProbeEntry('发动机ECM', '7E0', '222008', '累计燃油消耗总量 (Total Fuel Consumed L)'),
    ];
  }

  ObdGattChannel? _resolveObdGattChannel(List<BluetoothService> services) {
    const excludedServicePrefixes = [
      '00001800', // Generic Access (0x2A00 Device Name)
      '00001801', // Generic Attribute (0x2A05 Service Changed)
      '0000180a', // Device Information
      '0000180f', // Battery Service
      '00001805', // Current Time
      '00001804', // Tx Power
      '00001803', // Link Loss
      '00001802', // Immediate Alert
    ];

    bool isSigExcluded(String uuid) {
      final lower = uuid.toLowerCase();
      return excludedServicePrefixes.any((prefix) => lower.startsWith(prefix));
    }

    // 1. Veepeak / Vgate / Generic FFF0 Profile (Service: 0xFFF0, Write: 0xFFF2, Notify: 0xFFF1)
    for (final service in services) {
      final sUuid = service.uuid.str128.toLowerCase();
      if (sUuid.contains('fff0')) {
        BluetoothCharacteristic? w;
        BluetoothCharacteristic? n;
        for (final c in service.characteristics) {
          final cUuid = c.uuid.str128.toLowerCase();
          final props = c.properties;
          if (cUuid.contains('fff2') || (props.write || props.writeWithoutResponse)) {
            if (props.write || props.writeWithoutResponse) w ??= c;
          }
          if (cUuid.contains('fff1') || (props.notify || props.indicate)) {
            if (props.notify || props.indicate) n ??= c;
          }
        }
        if (w != null && n != null) {
          return ObdGattChannel(
            service: service,
            writeCharacteristic: w,
            notifyCharacteristic: n,
            profileName: 'Veepeak/Vgate FFF0',
          );
        }
      }
    }

    // 2. Nordic UART Service (NUS) (Service: 6E400001, Write: 6E400002, Notify: 6E400003)
    for (final service in services) {
      final sUuid = service.uuid.str128.toLowerCase();
      if (sUuid.contains('6e400001')) {
        BluetoothCharacteristic? w;
        BluetoothCharacteristic? n;
        for (final c in service.characteristics) {
          final cUuid = c.uuid.str128.toLowerCase();
          final props = c.properties;
          if (cUuid.contains('6e400002') && (props.write || props.writeWithoutResponse)) {
            w = c;
          } else if (cUuid.contains('6e400003') && (props.notify || props.indicate)) {
            n = c;
          }
        }
        if (w != null && n != null) {
          return ObdGattChannel(
            service: service,
            writeCharacteristic: w,
            notifyCharacteristic: n,
            profileName: 'Nordic UART Service (NUS)',
          );
        }
      }
    }

    // 3. ISSC / Microchip Transparent UART (Service: 49535343, Write: 1E4D, Notify: 8841)
    for (final service in services) {
      final sUuid = service.uuid.str128.toLowerCase();
      if (sUuid.contains('49535343')) {
        BluetoothCharacteristic? w;
        BluetoothCharacteristic? n;
        for (final c in service.characteristics) {
          final cUuid = c.uuid.str128.toLowerCase();
          final props = c.properties;
          if ((cUuid.contains('1e4d') || props.write || props.writeWithoutResponse) && w == null) {
            if (props.write || props.writeWithoutResponse) w = c;
          }
          if ((cUuid.contains('8841') || props.notify || props.indicate) && n == null) {
            if (props.notify || props.indicate) n = c;
          }
        }
        if (w != null && n != null) {
          return ObdGattChannel(
            service: service,
            writeCharacteristic: w,
            notifyCharacteristic: n,
            profileName: 'ISSC/Microchip UART',
          );
        }
      }
    }

    // 4. Custom Automotive 18F0 Profile (Service: 18F0)
    for (final service in services) {
      final sUuid = service.uuid.str128.toLowerCase();
      if (sUuid.contains('18f0')) {
        BluetoothCharacteristic? w;
        BluetoothCharacteristic? n;
        for (final c in service.characteristics) {
          final props = c.properties;
          if (w == null && (props.write || props.writeWithoutResponse)) {
            w = c;
          }
          if (n == null && (props.notify || props.indicate)) {
            n = c;
          }
        }
        if (w != null && n != null) {
          return ObdGattChannel(
            service: service,
            writeCharacteristic: w,
            notifyCharacteristic: n,
            profileName: 'Automotive 18F0',
          );
        }
      }
    }

    // 5. HM-10 / CC2541 Profile (Service: 0xFFE0, Characteristic: 0xFFE1)
    for (final service in services) {
      final sUuid = service.uuid.str128.toLowerCase();
      if (sUuid.contains('ffe0')) {
        BluetoothCharacteristic? w;
        BluetoothCharacteristic? n;
        for (final c in service.characteristics) {
          final cUuid = c.uuid.str128.toLowerCase();
          final props = c.properties;
          if (cUuid.contains('ffe1') || (props.write || props.writeWithoutResponse)) {
            if (props.write || props.writeWithoutResponse) w ??= c;
            if (props.notify || props.indicate) n ??= c;
          }
        }
        if (w != null && n != null) {
          return ObdGattChannel(
            service: service,
            writeCharacteristic: w,
            notifyCharacteristic: n,
            profileName: 'HM-10 FFE0/FFE1',
          );
        }
      }
    }

    // 6. 通用后备匹配: 遍历非 SIG 专用服务，严格在同一自定义服务内成对提取写/读特征
    for (final service in services) {
      final sUuid = service.uuid.str128.toLowerCase();
      if (isSigExcluded(sUuid)) continue;

      BluetoothCharacteristic? combinedChar;
      BluetoothCharacteristic? w;
      BluetoothCharacteristic? n;

      for (final c in service.characteristics) {
        final props = c.properties;
        final isWritable = props.write || props.writeWithoutResponse;
        final isNotifiable = props.notify || props.indicate;

        if (isWritable && isNotifiable) {
          combinedChar = c;
          break;
        }
        if (isWritable && w == null) w = c;
        if (isNotifiable && n == null) n = c;
      }

      if (combinedChar != null) {
        return ObdGattChannel(
          service: service,
          writeCharacteristic: combinedChar,
          notifyCharacteristic: combinedChar,
          profileName: 'Custom Single-Char UART (${service.uuid.str128})',
        );
      }

      if (w != null && n != null) {
        return ObdGattChannel(
          service: service,
          writeCharacteristic: w,
          notifyCharacteristic: n,
          profileName: 'Custom Dual-Char UART (${service.uuid.str128})',
        );
      }
    }

    return null;
  }

  @visibleForTesting
  ObdGattChannel? resolveObdGattChannelForTesting(List<BluetoothService> services) =>
      _resolveObdGattChannel(services);

  @visibleForTesting
  double? parseStandardSpeed(String resp) => _parseStandardSpeed(resp);

  @visibleForTesting
  double? parseStandardRpm(String resp) => _parseStandardRpm(resp);

  @visibleForTesting
  double? parseStandardTemp(String resp) => _parseStandardTemp(resp);

  @visibleForTesting
  double? parseAtRv(String resp) => _parseAtRv(resp);

  @visibleForTesting
  double? parsePercent(String resp) => _parsePercent(resp);

  @visibleForTesting
  Future<void> pollCycleForTesting() => _pollCycle();

  void dispose() {
    disconnect();
    telemetryNotifier.dispose();
    scanResultsNotifier.dispose();
    isScanningNotifier.dispose();
    debugLogNotifier.dispose();
    isDeepScanningNotifier.dispose();
    lastDeepScanReportNotifier.dispose();
  }
}

class _ProbeEntry {
  final String category;
  final String? header;
  final String cmd;
  final String name;

  const _ProbeEntry(this.category, this.header, this.cmd, this.name);
}

class ObdGattChannel {
  final BluetoothService service;
  final BluetoothCharacteristic writeCharacteristic;
  final BluetoothCharacteristic notifyCharacteristic;
  final String profileName;

  const ObdGattChannel({
    required this.service,
    required this.writeCharacteristic,
    required this.notifyCharacteristic,
    required this.profileName,
  });
}
