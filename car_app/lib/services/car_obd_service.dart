import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/obd_telemetry.dart';

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

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeCharacteristic;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  final StringBuffer _rxBuffer = StringBuffer();
  Completer<String>? _cmdCompleter;
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
      BluetoothCharacteristic? writeChar;
      BluetoothCharacteristic? notifyChar;

      for (final service in services) {
        for (final char in service.characteristics) {
          final props = char.properties;
          final isWritable = props.write || props.writeWithoutResponse;
          final isNotifiable = props.notify || props.indicate;

          // 匹配常见 OBD BLE 串口特征值 (0xFFE1, Nordic UART, 或兼具读写特征)
          final uuidStr = char.uuid.str128.toLowerCase();
          if (uuidStr.contains('ffe1') ||
              uuidStr.contains('6e400002') ||
              uuidStr.contains('6e400003') ||
              uuidStr.contains('18f0') ||
              (isWritable && isNotifiable)) {
            if (isWritable && writeChar == null) writeChar = char;
            if (isNotifiable && notifyChar == null) notifyChar = char;
          }
        }
      }

      // 若未精准匹配特定 UUID，寻找第一个可写且可通知的特征
      if (writeChar == null || notifyChar == null) {
        for (final service in services) {
          for (final char in service.characteristics) {
            if (writeChar == null &&
                (char.properties.write || char.properties.writeWithoutResponse)) {
              writeChar = char;
            }
            if (notifyChar == null &&
                (char.properties.notify || char.properties.indicate)) {
              notifyChar = char;
            }
          }
        }
      }

      if (writeChar == null || notifyChar == null) {
        log('❌ 未能在该设备中找到兼容的串口 GATT 读写通道');
        await disconnect();
        _updateStatus(ObdConnectionStatus.error, message: '未找到 OBD 串口特征值');
        return false;
      }

      _writeCharacteristic = writeChar;

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

      _updateStatus(
        ObdConnectionStatus.ready,
        message: 'OBD 连接就绪，开始实时采集',
        deviceName: deviceName,
        deviceId: device.remoteId.str,
      );
      log('🎉 OBD2 适配器已成功锁定 ISO 15765-4 CAN 协议并进入就绪态');

      _startPolling();
      return true;
    } catch (e) {
      log('❌ 连接失败: $e');
      await disconnect();
      _updateStatus(ObdConnectionStatus.error, message: '连接失败: $e');
      return false;
    }
  }

  // --- 3. ELM327 AT 指令集初始化流程 ---
  Future<bool> _initializeElm327() async {
    try {
      // 1. 复位
      var resp = await sendRawCommand('ATZ', timeout: const Duration(seconds: 2));
      log('ATZ 应答: $resp');

      // 2. 关闭回显
      await sendRawCommand('ATE0');
      // 3. 关闭换行符
      await sendRawCommand('ATL0');
      // 4. 关闭空格加速传输
      await sendRawCommand('ATS0');
      // 5. 关闭报头 (默认)
      await sendRawCommand('ATH0');
      // 6. 自适应超时
      await sendRawCommand('ATAT1');
      // 7. 锁定丰田 CAN 协议: ISO 15765-4 CAN 11-bit 500k
      resp = await sendRawCommand('ATSP6');
      log('ATSP6 (锁定 CAN 11-bit 500k) 应答: $resp');

      // 8. 测试读取支持的 PID 0100 确认车辆 CAN 就绪
      resp = await sendRawCommand('0100', timeout: const Duration(seconds: 3));
      log('0100 测试应答: $resp');

      return resp.isNotEmpty && !resp.contains('UNABLE') && !resp.contains('ERROR');
    } catch (e) {
      log('初始化指令异常: $e');
      return false;
    }
  }

  // --- 4. 周期调度与分级轮询引擎 ---
  void _startPolling() {
    _pollingTimer?.cancel();
    _pollCycleCount = 0;
    // 每 1.2 秒触发一次调度轮询
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1200), (timer) {
      _pollCycle();
    });
  }

  Future<void> _pollCycle() async {
    if (_isPollingBusy || !isConnected) return;
    _isPollingBusy = true;
    _pollCycleCount++;

    try {
      // ---------------------------------------------------------------------
      // Tier 1: 高频队列 (每次轮询都查: 车速、转速、冷却液水温)
      // ---------------------------------------------------------------------
      await _queryStandardEngineTier1();

      // ---------------------------------------------------------------------
      // Tier 2: 混动动力电池与电驱系统 (每 2 次循环约 2.4s 查一次)
      // ---------------------------------------------------------------------
      if (_pollCycleCount % 2 == 0) {
        await _queryToyotaHybridTier2();
      }

      // ---------------------------------------------------------------------
      // Tier 3: 发动机高级指标与整车状态 (每 5 次循环约 6s 查一次)
      // ---------------------------------------------------------------------
      if (_pollCycleCount % 5 == 0) {
        await _queryToyotaEngineAndAuxTier3();
      }

      // ---------------------------------------------------------------------
      // Tier 4: 低频/静态数据 (每 25 次循环约 30s 查一次: 里程、油位)
      // ---------------------------------------------------------------------
      if (_pollCycleCount % 25 == 0) {
        await _queryLowFrequencyTier4();
      }
    } catch (e) {
      log('轮询周期发生异常: $e');
    } finally {
      _isPollingBusy = false;
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
    if (clean.length >= 6) {
      final hexVal = clean.substring(clean.length - 2);
      final val = int.tryParse(hexVal, radix: 16);
      if (val != null) return val - 40.0;
    }
    return null;
  }

  // 0111 / 0104: (XX * 100) / 255
  double? _parsePercent(String resp) {
    final clean = _cleanHex(resp);
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
    final writeChar = _writeCharacteristic;
    if (writeChar == null || _connectedDevice == null) {
      return 'ERROR: DISCONNECTED';
    }

    _rxBuffer.clear();
    _cmdCompleter = Completer<String>();

    final formatted = '${command.trim()}\r';
    final bytes = ascii.encode(formatted);

    try {
      if (writeChar.properties.writeWithoutResponse) {
        await writeChar.write(bytes, withoutResponse: true);
      } else {
        await writeChar.write(bytes, withoutResponse: false);
      }

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

  void dispose() {
    disconnect();
    telemetryNotifier.dispose();
    scanResultsNotifier.dispose();
    isScanningNotifier.dispose();
    debugLogNotifier.dispose();
  }
}
