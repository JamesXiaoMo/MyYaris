import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/obd_telemetry.dart';
import '../models/elm_obd_response.dart';
import '../models/obd_deep_scan_result.dart';
import '../models/toyota_tnga_profile.dart';
import 'obd_transport_journal.dart';

class CarObdService {
  static final CarObdService _instance = CarObdService._internal();
  factory CarObdService() => _instance;
  CarObdService._internal();

  /// Isolated instance exercising the real serial queue with a fake BLE writer.
  @visibleForTesting
  CarObdService.forTesting(
    Future<void> Function(List<int>) writer, {
    Future<void> Function(Map<String, dynamic>)? journalSink,
  }) : _testWriter = writer,
       _testJournalSink = journalSink {
    _updateStatus(ObdConnectionStatus.ready);
  }
  Future<void> Function(List<int>)? _testWriter;
  Future<void> Function(Map<String, dynamic>)? _testJournalSink;
  late final ObdTransportJournal _journal = ObdTransportJournal(
    test: _testWriter != null,
    sink: _testJournalSink,
  );
  int _transactionSequence = 0;
  int _notificationSequence = 0;
  int? _transactionId;
  int? _observedMtu;
  StreamSubscription<int>? _mtuSubscription;
  Map<String, dynamic>? _exchangeStats;
  Future<void>? _pendingWrite;
  bool _replyPromptSeen = true;
  final StringBuffer _trailingRx = StringBuffer();
  final ValueNotifier<String> diagnosticStateNotifier = ValueNotifier('尚未开始诊断');

  bool get isPollingSuspended => _pollingSuspended;
  void _transportEvent(String phase, [Map<String, dynamic> fields = const {}]) {
    _journal.record(phase, {'transaction_id': _transactionId, ...fields});
  }

  final Object _sequenceKey = Object();
  Object? _sequenceOwner;
  Completer<void>? _sequenceDone;
  bool _serialSynchronized = true;
  Completer<void>? _drained;
  String? _knownHeader;
  String? _knownDisplay;
  String? _knownProtocol;
  String? _knownFormatting;
  bool _pollingSuspended = false;
  bool _activeInterrupted = false;
  bool _scanOwnsSerial = false;
  bool _restoringScanState = false;
  final List<Map<String, dynamic>> _scanLateReplies = [];

  Future<T> _sequence<T>(Future<T> Function() work) async {
    while (_sequenceDone != null) {
      await _sequenceDone!.future;
    }
    final done = Completer<void>();
    final owner = Object();
    _sequenceDone = done;
    _sequenceOwner = owner;
    try {
      return await runZoned(work, zoneValues: {_sequenceKey: owner});
    } finally {
      _sequenceOwner = null;
      _sequenceDone = null;
      done.complete();
    }
  }

  @visibleForTesting
  void receiveForTesting(String value) => _onDataReceived(ascii.encode(value));
  @visibleForTesting
  void receiveBytesForTesting(List<int> bytes) => _onDataReceived(bytes);
  @visibleForTesting
  Future<ElmReply> exchangeForTesting(
    String cmd, {
    required Duration timeout,
  }) => _exchange(cmd, timeout: timeout);
  @visibleForTesting
  Future<void> flushJournalForTesting() => _journal.flush();
  @visibleForTesting
  void disconnectForTesting() => _handleDisconnection();

  static const String _prefLastDeviceAddress = 'obd_last_device_address';
  static const String _prefLastDeviceName = 'obd_last_device_name';

  /// 当前生效的车型协议数据集配置文件
  String get currentProfileName => ToyotaTngaHybridProfile.profileName;

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
  final ValueNotifier<bool> enableStandardPollingNotifier = ValueNotifier<bool>(
    false,
  );

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
  Future<void> startScan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
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
      _updateStatus(
        ObdConnectionStatus.scanning,
        message: '正在扫描周边 OBD 蓝牙设备...',
      );
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
      _observedMtu = null;
      try {
        if (!kIsWeb) {
          _observedMtu = await device.requestMtu(247);
        }
      } catch (e) {
        log('MTU 协商忽略: $e');
      }

      _mtuSubscription?.cancel();
      _mtuSubscription = device.mtu.listen((mtu) {
        _observedMtu = mtu;
        _transportEvent('mtu', {'mtu': mtu});
      });
      log('🔎 正在发现 GATT 服务与串口特征值...');
      final services = await device.discoverServices();
      final channel = _resolveObdGattChannel(services);

      if (channel == null) {
        log('❌ 未能在该设备中找到兼容的串口 GATT 读写通道');
        await disconnect();
        _updateStatus(ObdConnectionStatus.error, message: '未找到 OBD 串口特征值');
        return false;
      }

      _pollingSuspended = false;
      _serialSynchronized = true;
      _drained = null;
      _replyPromptSeen = true;
      _rxBuffer.clear();
      _trailingRx.clear();
      _transactionId = null;
      _exchangeStats = null;
      _transportEvent('connection', {'mtu': _observedMtu});
      diagnosticStateNotifier.value = '串口已连接，尚未进行诊断';
      _knownHeader = null;
      _knownDisplay = null;
      _knownProtocol = null;
      _knownFormatting = null;
      _writeCharacteristic = channel.writeCharacteristic;
      final notifyChar = channel.notifyCharacteristic;

      log('🎯 锁定 OBD 通信通道 [${channel.profileName}]');
      log('   🔹 服务: ${channel.service.uuid.str128}');
      log('   🔸 TX写特征: ${channel.writeCharacteristic.uuid.str128}');
      log('   🔸 RX读特征: ${channel.notifyCharacteristic.uuid.str128}');

      // 开启数据下行监听
      await notifyChar.setNotifyValue(true);
      _notifySubscription = notifyChar.onValueReceived.listen(_onDataReceived);

      _updateStatus(
        ObdConnectionStatus.initializing,
        message: '正在初始化 ELM327 适配器...',
      );
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
      var resp = await sendRawCommand(
        'ATZ',
        timeout: const Duration(seconds: 2),
      );
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
        _updateTelemetry((t) => t.copyWith(aux12vVoltage: battV));
      }

      // 5. 关闭空格加速传输
      await sendRawCommand('ATS0');
      await sendRawCommand(
        'ATCAF1',
      ); // Explicit application request formatting; CFC is independent.

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

      if (ElmObdParser.classify(
        ElmReply(
          resp,
          resp.startsWith('TIMEOUT') || resp.startsWith('ERROR')
              ? 'incomplete'
              : 'prompt',
        ),
        '0100',
      ).positive) {
        canBusReady = true;
        canBusReadyNotifier.value = true;
        log('🎉 车辆 ECU 已成功响应 PID 0100，标准 CAN 总线已联机');
      } else {
        canBusReady = false;
        canBusReadyNotifier.value = false;
        log('ℹ️ 车辆 ECU 未响应 PID 0100 (应答: $resp)，适配器保持监听，等待车辆通电');
      }

      // 只要适配器能响应 AT 指令 (ATE0/ATI/ATRV 正常返回非 ERROR)，即认定适配器链路正常
      final adapterOk =
          (ate0Resp.isNotEmpty && !ate0Resp.startsWith('ERROR')) ||
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
    if (!isConnected || _pollingSuspended || _testWriter != null) return;
    _pollCycleCount = 0;
    // 基础安全轮询周期 2.5 秒
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 2500), (timer) {
      _pollCycle();
    });
  }

  Future<void> _pollCycle() async {
    if (_isPollingBusy ||
        !isConnected ||
        _isDeepScanning ||
        _pollingSuspended ||
        _sequenceDone != null ||
        _cmdQueue != null) {
      return;
    }
    await _sequence(_pollCycleOwned);
  }

  Future<void> _pollCycleOwned() async {
    _isPollingBusy = true;
    _pollCycleCount++;

    try {
      // 基础安全轮询: 仅读取适配器 12V 蓄电池引脚电压 (引脚16独立 ADC 测量，不向车辆发送任何 CAN 诊断报文)
      final atrv = await sendRawCommand('ATRV');
      final battV = _parseAtRv(atrv);
      if (battV != null) {
        _updateTelemetry(
          (t) => t.copyWith(aux12vVoltage: battV, lastUpdated: DateTime.now()),
        );
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
    if (_isDeepScanning || _sequenceDone != null || _cmdQueue != null) {
      log('扫描/轮询事务占用串口，拒绝单次验证');
      return;
    }
    await _sequence(_verifyStandardPidsOwned);
  }

  Future<void> _verifyStandardPidsOwned() async {
    if (!isConnected) {
      log('⚠️ 适配器未连接，无法执行标准 PID 验证');
      return;
    }
    log('🔬 [显式验证] 正在发送标准 OBD 0100 指令探测车辆 CAN 总线...');
    final resp0100 = await sendRawCommand('0100');
    log('🔬 [显式验证] 0100 应答: $resp0100');

    if (ElmObdParser.classify(
      ElmReply(
        resp0100,
        resp0100.startsWith('TIMEOUT') || resp0100.startsWith('ERROR')
            ? 'incomplete'
            : 'prompt',
      ),
      '0100',
    ).positive) {
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

    _updateTelemetry(
      (t) => t.copyWith(
        speedKmh: speed ?? t.speedKmh,
        engineRpm: rpm ?? t.engineRpm,
        coolantTemp: coolant ?? t.coolantTemp,
        lastUpdated: DateTime.now(),
      ),
    );
  }

  // Tier 2: 丰田混动 (支持 TNGA Mode 22 DID 与老款 Mode 21)
  // Header 0x7E2 / 221024 (SoC, 电池总压, 充放电流) & 221100 (升压VL/VH, 逆变器温度) & 221102 (双电机转速/扭矩)
  // Header 0x7EB / 222884 (电芯压差) & 222885 (6点温感)
  Future<void> _queryToyotaHybridTier2() async {
    // 1. 混动核心电脑 0x7E2
    await sendRawCommand('ATSH7E2');
    final c221024 = await sendRawCommand('221024');
    _parseToyotaTnga221024(c221024);

    final c221100 = await sendRawCommand('221100');
    _parseToyotaTnga221100(c221100);

    final c221102 = await sendRawCommand('221102');
    _parseToyotaTnga221102(c221102);

    // 兼容老款车型 (Prius 3代 Mode 21)
    if (!c221024.contains('621024')) {
      final c3Resp = await sendRawCommand('21C3');
      _parseToyota21C3(c3Resp);
    }
    if (!c221100.contains('621100')) {
      final c4Resp = await sendRawCommand('21C4');
      _parseToyota21C4(c4Resp);
    }

    // 2. 动力电池电脑 0x7EB
    await sendRawCommand('ATSH7EB');
    final c222884 = await sendRawCommand('222884');
    _parseToyotaTnga222884(c222884);

    final c222885 = await sendRawCommand('222885');
    _parseToyotaTnga222885(c222885);

    // 3. 发动机 ECM 0x7E0 (电子水泵等)
    await sendRawCommand('ATSH7E0');
    final c221234 = await sendRawCommand('221234');
    _parseToyotaTnga221234(c221234);

    // 切回标准广播报头
    await sendRawCommand('ATSH7DF');
  }

  // Tier 3: 辅助 12V 电池、机油温度、节气门与进气
  Future<void> _queryToyotaEngineAndAuxTier3() async {
    // 1. 读取 12V 电池电压 (优先标准 Mode 01 PID 0142，失败走 ATRV)
    final resp0142 = await sendRawCommand('0142');
    double? auxV = _parseStandardModuleVoltage(resp0142);
    if (auxV == null) {
      final rvResp = await sendRawCommand('ATRV');
      auxV = _parseAtRv(rvResp);
    }

    // 2. 读取节气门开度 (0111) 与 发动机负荷 (0104)
    final thResp = await sendRawCommand('0111');
    final throttle = _parsePercent(thResp);

    final loadResp = await sendRawCommand('0104');
    final load = _parsePercent(loadResp);

    // 3. 进气温度 (010F) 与 发动机机油温度 (015C)
    final iatResp = await sendRawCommand('010F');
    final iat = _parseStandardTemp(iatResp);

    final oilResp = await sendRawCommand('015C');
    final oilTemp = _parseStandardTemp(oilResp);

    // 4. 进气空气质量流量 MAF (0110) 与 绝对大气压 (0133)
    final mafResp = await sendRawCommand('0110');
    final maf = _parseStandardMaf(mafResp);

    final baroResp = await sendRawCommand('0133');
    final baro = _parseStandardBaro(baroResp);

    // 5. 短期燃油修正 STFT (0106) 与 长期燃油修正 LTFT (0107)
    final stftResp = await sendRawCommand('0106');
    final stft = _parseFuelTrim(stftResp);

    final ltftResp = await sendRawCommand('0107');
    final ltft = _parseFuelTrim(ltftResp);

    // 6. 空燃比当量比 Lambda (0134)
    final lambdaResp = await sendRawCommand('0134');
    final lambda = _parseLambda(lambdaResp);

    // 7. 油门踏板位置 (0149 Pedal D, 014A Pedal E) 与节气门作动器指令 (014C)
    final pedalDResp = await sendRawCommand('0149');
    final pedalD = _parsePercent(pedalDResp);

    final pedalEResp = await sendRawCommand('014A');
    final pedalE = _parsePercent(pedalEResp);

    final thActResp = await sendRawCommand('014C');
    final thAct = _parsePercent(thActResp);

    final relThResp = await sendRawCommand('0145');
    final relTh = _parsePercent(relThResp);

    _updateTelemetry(
      (t) => t.copyWith(
        aux12vVoltage: auxV ?? t.aux12vVoltage,
        throttlePosition: throttle ?? t.throttlePosition,
        relativeThrottlePosition: relTh ?? t.relativeThrottlePosition,
        commandedThrottleActuator: thAct ?? t.commandedThrottleActuator,
        pedalPositionD: pedalD ?? t.pedalPositionD,
        pedalPositionE: pedalE ?? t.pedalPositionE,
        engineLoad: load ?? t.engineLoad,
        intakeAirTemp: iat ?? t.intakeAirTemp,
        engineOilTemp: oilTemp ?? t.engineOilTemp,
        mafGramsPerSec: maf ?? t.mafGramsPerSec,
        barometricPressureKpa: baro ?? t.barometricPressureKpa,
        shortTermFuelTrim: stft ?? t.shortTermFuelTrim,
        longTermFuelTrim: ltft ?? t.longTermFuelTrim,
        equivalenceRatio: lambda ?? t.equivalenceRatio,
        lastUpdated: DateTime.now(),
      ),
    );
  }

  // Tier 4: 里程 (ODO)、催化转化器温与低频专用传感器
  Future<void> _queryLowFrequencyTier4() async {
    // 1. 读取仪表累计总里程 (01A6)
    final odoResp = await sendRawCommand('01A6');
    final odo = _parseStandardOdometer(odoResp);

    // 2. 读取催化转化器温度 (013C & 013D)
    final catResp = await sendRawCommand('013C');
    final catTemp = _parseStandardCatTemp(catResp);

    final cat2Resp = await sendRawCommand('013D');
    final catTemp2 = _parseStandardCatTemp(cat2Resp);

    // 3. 读取发动机本次运行时间 (011F) 与 车外环境空气温度 (0146)
    final runResp = await sendRawCommand('011F');
    final runTime = _parseRunTime(runResp);

    final ambResp = await sendRawCommand('0146');
    final ambTemp = _parseStandardTemp(ambResp);

    // 4. 切换至混动 0x7E2 读 HV 里程 (222006)
    await sendRawCommand('ATSH7E2');
    final hvOdoResp = await sendRawCommand('222006');
    _parseToyotaTnga222006(hvOdoResp);

    // 5. 切换至发动机 ECM 0x7E0
    await sendRawCommand('ATSH7E0');
    final ecm221234 = await sendRawCommand('221234');
    _parseToyotaTnga221234(ecm221234);

    if (!ecm221234.contains('621234')) {
      final ecmResp = await sendRawCommand('21CE');
      _parseToyotaEcm21CE(ecmResp);
    }

    // 切回标准广播报头
    await sendRawCommand('ATSH7DF');

    _updateTelemetry(
      (t) => t.copyWith(
        totalOdometerKm: odo ?? t.totalOdometerKm,
        catalystTemp: catTemp ?? t.catalystTemp,
        catalystTemp2: catTemp2 ?? t.catalystTemp2,
        runTimeSeconds: runTime ?? t.runTimeSeconds,
        ambientAirTemp: ambTemp ?? t.ambientAirTemp,
        lastUpdated: DateTime.now(),
      ),
    );
  }

  // --- 5. 数据解码器 (Parser 实现) ---

  // 010D: 41 0D XX -> XX (km/h)
  double? _parseStandardSpeed(String resp) {
    final clean = _matchedPayload(resp, const ['010D']);
    final idx = clean.indexOf('410D');
    if (idx != -1 && clean.length >= idx + 6) {
      final hexA = clean.substring(idx + 4, idx + 6);
      return int.tryParse(hexA, radix: 16)?.toDouble();
    }
    return null;
  }

  // 010C: 41 0C AA BB -> ((AA*256)+BB)/4
  double? _parseStandardRpm(String resp) {
    final clean = _matchedPayload(resp, const ['010C']);
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

  // 0105 / 010F / 0146 / 015C: 41 XX YY -> YY - 40
  double? _parseStandardTemp(String resp) {
    final clean = _matchedPayload(resp, const ['0105', '010F', '0146', '015C']);
    final match = RegExp(r'41(05|0F|46|5C)([0-9A-F]{2})').firstMatch(clean);
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

  // 0111 / 0104 / 012F / 0145 / 0149 / 014A / 014C: (XX * 100) / 255
  double? _parsePercent(String resp) {
    final clean = _matchedPayload(resp, const [
      '0111',
      '0104',
      '012F',
      '0145',
      '0149',
      '014A',
      '014C',
    ]);
    final match = RegExp(
      r'41(11|04|2F|45|49|4A|4C)([0-9A-F]{2})',
    ).firstMatch(clean);
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

  // 0106 / 0107: 41 06 XX -> (XX - 128) * 100 / 128 (%)
  double? _parseFuelTrim(String resp) {
    final clean = _matchedPayload(resp, const ['0106', '0107']);
    final match = RegExp(r'41(06|07)([0-9A-F]{2})').firstMatch(clean);
    if (match != null) {
      final val = int.tryParse(match.group(2)!, radix: 16);
      if (val != null) return ((val - 128) * 100.0) / 128.0;
    }
    return null;
  }

  // 010E: 41 0E XX -> (XX - 128) / 2 (°)
  double? _parseTimingAdvance(String resp) {
    final clean = _matchedPayload(resp, const ['010E']);
    final idx = clean.indexOf('410E');
    if (idx != -1 && clean.length >= idx + 6) {
      final hexA = clean.substring(idx + 4, idx + 6);
      final val = int.tryParse(hexA, radix: 16);
      if (val != null) return (val - 128) / 2.0;
    }
    return null;
  }

  // 011F: 41 1F AA BB -> (AA * 256) + BB (s)
  int? _parseRunTime(String resp) {
    final clean = _matchedPayload(resp, const ['011F']);
    final idx = clean.indexOf('411F');
    if (idx != -1 && clean.length >= idx + 8) {
      final hexVal = clean.substring(idx + 4, idx + 8);
      return int.tryParse(hexVal, radix: 16);
    }
    return null;
  }

  // 0134: 41 34 AA BB -> ((AA * 256) + BB) / 32768 (Lambda)
  double? _parseLambda(String resp) {
    final clean = _matchedPayload(resp, const ['0134']);
    final idx = clean.indexOf('4134');
    if (idx != -1 && clean.length >= idx + 8) {
      final hexVal = clean.substring(idx + 4, idx + 8);
      final raw = int.tryParse(hexVal, radix: 16);
      if (raw != null) return raw / 32768.0;
    }
    return null;
  }

  // 0142: 41 42 AA BB -> ((AA * 256) + BB) / 1000 (V)
  double? _parseStandardModuleVoltage(String resp) {
    final clean = _matchedPayload(resp, const ['0142']);
    final idx = clean.indexOf('4142');
    if (idx != -1 && clean.length >= idx + 8) {
      final hexA = clean.substring(idx + 4, idx + 6);
      final hexB = clean.substring(idx + 6, idx + 8);
      final valA = int.tryParse(hexA, radix: 16);
      final valB = int.tryParse(hexB, radix: 16);
      if (valA != null && valB != null) {
        return ((valA * 256) + valB) / 1000.0;
      }
    }
    return null;
  }

  // 01A6: 41 A6 AA BB CC DD -> ((AA * 16^6) + (BB * 16^4) + (CC * 16^2) + DD) / 10 (km)
  double? _parseStandardOdometer(String resp) {
    final clean = _matchedPayload(resp, const ['01A6']);
    final idx = clean.indexOf('41A6');
    if (idx != -1 && clean.length >= idx + 12) {
      final hexOdo = clean.substring(idx + 4, idx + 12);
      final rawVal = int.tryParse(hexOdo, radix: 16);
      if (rawVal != null) {
        return rawVal / 10.0;
      }
    }
    return null;
  }

  // 0110: 41 10 AA BB -> ((AA * 256) + BB) / 100 (g/s)
  double? _parseStandardMaf(String resp) {
    final clean = _matchedPayload(resp, const ['0110']);
    final idx = clean.indexOf('4110');
    if (idx != -1 && clean.length >= idx + 8) {
      final hexA = clean.substring(idx + 4, idx + 6);
      final hexB = clean.substring(idx + 6, idx + 8);
      final valA = int.tryParse(hexA, radix: 16);
      final valB = int.tryParse(hexB, radix: 16);
      if (valA != null && valB != null) {
        return ((valA * 256) + valB) / 100.0;
      }
    }
    return null;
  }

  // 0133: 41 33 AA -> AA (kPa)
  double? _parseStandardBaro(String resp) {
    final clean = _matchedPayload(resp, const ['0133']);
    final idx = clean.indexOf('4133');
    if (idx != -1 && clean.length >= idx + 6) {
      final hexA = clean.substring(idx + 4, idx + 6);
      final val = int.tryParse(hexA, radix: 16);
      if (val != null) return val.toDouble();
    }
    return null;
  }

  // 013C / 013D: 41 3C/3D AA BB -> (((AA * 256) + BB) / 10) - 40 (°C)
  double? _parseStandardCatTemp(String resp) {
    final clean = _matchedPayload(resp, const ['013C', '013D']);
    final match = RegExp(r'41(3C|3D)([0-9A-F]{4})').firstMatch(clean);
    if (match != null) {
      final hexVal = match.group(2)!;
      final rawVal = int.tryParse(hexVal, radix: 16);
      if (rawVal != null) {
        return (rawVal / 10.0) - 40.0;
      }
    }
    final idx = clean.indexOf('413C');
    if (idx != -1 && clean.length >= idx + 8) {
      final hexA = clean.substring(idx + 4, idx + 6);
      final hexB = clean.substring(idx + 6, idx + 8);
      final valA = int.tryParse(hexA, radix: 16);
      final valB = int.tryParse(hexB, radix: 16);
      if (valA != null && valB != null) {
        return (((valA * 256) + valB) / 10.0) - 40.0;
      }
    }
    return null;
  }

  // AT RV: 例如 "14.1V"
  double? _parseAtRv(String resp) {
    if (resp.startsWith('ERROR:') ||
        resp.contains('TIMEOUT') ||
        resp.contains('STOPPED')) {
      return null;
    }
    final match = RegExp(r'([0-9]+\.?[0-9]*)\s*V').firstMatch(resp);
    if (match != null) {
      return double.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  // --- 丰田 TNGA 第四代 THS-II UDS Mode 22 DID 解码器 ---

  // 221024: 混动高压电池遥测 (SOC %, 总压 V, 充放电流 A, 功率 kW)
  void _parseToyotaTnga221024(String resp) {
    final bytes = _extractPayloadBytes(resp, '621024');
    if (bytes == null || bytes.isEmpty) return;

    try {
      double? soc;
      double? vb;
      double? ib;

      // SoC (Byte 0): (Byte * 100) / 255
      if (bytes.isNotEmpty) {
        soc = (bytes[0] * 100.0) / 255.0;
      }

      // 电池总压 (Bytes 1-2): ((A << 8) | B) * 0.1 V
      if (bytes.length > 2) {
        final rawV = (bytes[1] << 8) | bytes[2];
        vb = rawV * 0.1;
      }

      // 充放电实时电流 (Bytes 3-4): 有符号 16-bit 偏移 32768, 精度 0.01 A
      if (bytes.length > 4) {
        final rawI = (bytes[3] << 8) | bytes[4];
        ib = (rawI - 32768) * 0.01;
      }

      double? powerKw;
      if (vb != null && ib != null) {
        powerKw = (vb * ib) / 1000.0;
      }

      _updateTelemetry(
        (t) => t.copyWith(
          batterySoc: soc ?? t.batterySoc,
          batteryVoltage: vb ?? t.batteryVoltage,
          batteryCurrent: ib ?? t.batteryCurrent,
          batteryPowerKw: powerKw ?? t.batteryPowerKw,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 TNGA 221024 失败: $e');
    }
  }

  // 221100: 升压变压器与逆变器热管理 (VL, VH, MG1/MG2 逆变器温, 变速箱油温)
  void _parseToyotaTnga221100(String resp) {
    final bytes = _extractPayloadBytes(resp, '621100');
    if (bytes == null || bytes.length < 6) return;

    try {
      final vl = (((bytes[0] << 8) | bytes[1]) * 0.1);
      final vh = (((bytes[2] << 8) | bytes[3]) * 0.1);
      final mg1T = (bytes[4] - 40).toDouble();
      final mg2T = (bytes[5] - 40).toDouble();
      double? transOil;
      if (bytes.length > 6) {
        transOil = (bytes[6] - 40).toDouble();
      }

      _updateTelemetry(
        (t) => t.copyWith(
          voltageBeforeBoost: vl,
          voltageAfterBoost: vh,
          mg1InverterTemp: mg1T,
          mg2InverterTemp: mg2T,
          transaxleOilTemp: transOil ?? t.transaxleOilTemp,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 TNGA 221100 失败: $e');
    }
  }

  // 221102: 双电机工况与扭矩 (MG1 RPM, MG2 RPM, MG2 扭矩, 再生制动力矩)
  void _parseToyotaTnga221102(String resp) {
    final bytes = _extractPayloadBytes(resp, '621102');
    if (bytes == null || bytes.length < 4) return;

    try {
      int rawMg1 = (bytes[0] << 8) | bytes[1];
      if (rawMg1 > 32767) rawMg1 -= 65536;

      int rawMg2 = (bytes[2] << 8) | bytes[3];
      if (rawMg2 > 32767) rawMg2 -= 65536;

      double? mg2T;
      if (bytes.length >= 6) {
        int rawT = (bytes[4] << 8) | bytes[5];
        if (rawT > 32767) rawT -= 65536;
        mg2T = rawT / 8.0;
      }

      double? regenT;
      if (bytes.length >= 8) {
        int rawR = (bytes[6] << 8) | bytes[7];
        if (rawR > 32767) rawR -= 65536;
        regenT = rawR / 8.0;
      }

      _updateTelemetry(
        (t) => t.copyWith(
          mg1Rpm: rawMg1.toDouble(),
          mg2Rpm: rawMg2.toDouble(),
          mg2Torque: mg2T ?? t.mg2Torque,
          regenBrakingTorque: regenT ?? t.regenBrakingTorque,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 TNGA 221102 失败: $e');
    }
  }

  // 222884: 动力电池极值与单体压差 (最高单体 V, 最低单体 V, 压差 Delta V, 平均单体 V)
  void _parseToyotaTnga222884(String resp) {
    final bytes = _extractPayloadBytes(resp, '622884');
    if (bytes == null || bytes.length < 4) return;

    try {
      final maxCell = (((bytes[0] << 8) | bytes[1]) / 1000.0);
      final minCell = (((bytes[2] << 8) | bytes[3]) / 1000.0);
      final delta = maxCell - minCell;
      double? avgCell;
      if (bytes.length >= 6) {
        final rawAvg = ((bytes[4] << 8) | bytes[5]);
        if (rawAvg > 0) {
          avgCell = rawAvg / 1000.0;
        }
      }
      avgCell ??= (maxCell + minCell) / 2.0;

      _updateTelemetry(
        (t) => t.copyWith(
          maxCellVoltage: maxCell,
          minCellVoltage: minCell,
          avgCellVoltage: avgCell,
          cellDeltaVoltage: delta,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 TNGA 222884 失败: $e');
    }
  }

  // 222885: 动力电池包 6 点温感监控
  void _parseToyotaTnga222885(String resp) {
    final bytes = _extractPayloadBytes(resp, '622885');
    if (bytes == null || bytes.isEmpty) return;

    try {
      final temps = <double>[];
      for (int i = 0; i < bytes.length && i < 6; i++) {
        temps.add((bytes[i] - 40).toDouble());
      }
      _updateTelemetry(
        (t) =>
            t.copyWith(batteryTemperatures: temps, lastUpdated: DateTime.now()),
      );
    } catch (e) {
      log('解析 TNGA 222885 失败: $e');
    }
  }

  // 221234: 电子冷却水泵转速与高阶热管理
  void _parseToyotaTnga221234(String resp) {
    final bytes = _extractPayloadBytes(resp, '621234');
    if (bytes == null || bytes.length < 2) return;

    try {
      final actualRpm = ((bytes[0] << 8) | bytes[1]).toDouble();
      double? targetRpm;
      if (bytes.length >= 4) {
        targetRpm = ((bytes[2] << 8) | bytes[3]).toDouble();
      }
      double? oilT;
      if (bytes.length > 4) {
        oilT = (bytes[4] - 40).toDouble();
      }

      _updateTelemetry(
        (t) => t.copyWith(
          electricWaterPumpRpm: actualRpm,
          electricWaterPumpTargetRpm: targetRpm ?? t.electricWaterPumpTargetRpm,
          engineOilTemp: oilT ?? t.engineOilTemp,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 TNGA 221234 失败: $e');
    }
  }

  // 222006: 混动系统记录总里程
  void _parseToyotaTnga222006(String resp) {
    final bytes = _extractPayloadBytes(resp, '622006');
    if (bytes == null || bytes.length < 3) return;

    try {
      int raw = 0;
      for (final b in bytes.take(4)) {
        raw = (raw << 8) | b;
      }
      final odo = raw / 10.0;
      _updateTelemetry(
        (t) => t.copyWith(
          totalOdometerKm: t.totalOdometerKm ?? odo,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 TNGA 222006 失败: $e');
    }
  }

  // --- 兼容旧版第三代混动 Mode 21 解码器 ---

  // 丰田混动 21C3 解码:
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

      _updateTelemetry(
        (t) => t.copyWith(
          batterySoc: soc ?? t.batterySoc,
          batteryVoltage: vb ?? t.batteryVoltage,
          batteryCurrent: ib ?? t.batteryCurrent,
          batteryPowerKw: powerKw ?? t.batteryPowerKw,
          mg1InverterTemp: mg1T ?? t.mg1InverterTemp,
          mg2InverterTemp: mg2T ?? t.mg2InverterTemp,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 21C3 失败: $e');
    }
  }

  // 丰田混动 21C4 解码:
  void _parseToyota21C4(String resp) {
    final bytes = _extractPayloadBytes(resp, '61C4');
    if (bytes == null || bytes.length < 6) return;

    try {
      final vl = (bytes[3] * 2).toDouble();
      final vh = (bytes[4] * 2).toDouble();

      _updateTelemetry(
        (t) => t.copyWith(
          voltageBeforeBoost: vl,
          voltageAfterBoost: vh,
          lastUpdated: DateTime.now(),
        ),
      );
    } catch (e) {
      log('解析 21C4 失败: $e');
    }
  }

  // 丰田 ECM 21CE 解码 (机油温度等)
  void _parseToyotaEcm21CE(String resp) {
    final bytes = _extractPayloadBytes(resp, '61CE');
    if (bytes == null || bytes.isEmpty) return;

    try {
      final oilTemp = (bytes[0] - 40).toDouble();
      _updateTelemetry(
        (t) => t.copyWith(engineOilTemp: oilTemp, lastUpdated: DateTime.now()),
      );
    } catch (e) {
      log('解析 21CE 失败: $e');
    }
  }

  List<int>? _extractPayloadBytes(String rawResp, String prefixHex) {
    final command =
        (int.parse(prefixHex.substring(0, 2), radix: 16) - 0x40)
            .toRadixString(16)
            .padLeft(2, '0')
            .toUpperCase() +
        prefixHex.substring(2);
    final clean = _matchedPayload(rawResp, [command]);
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

  String _matchedPayload(String raw, List<String> commands) {
    if (raw.startsWith('ERROR:') ||
        raw.contains('TIMEOUT') ||
        raw.contains('STOPPED')) {
      return '';
    }
    for (final cmd in commands) {
      final evidence = ElmObdParser.classify(ElmReply(raw, 'prompt'), cmd);
      for (final frame in evidence.frames) {
        if (frame.positive) return frame.payload;
      }
    }
    return '';
  }

  // --- 6. 指令发送与串口底层收发 ---
  Future<String> sendRawCommand(
    String command, {
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final reply = await _exchange(command, timeout: timeout);
    return reply.complete
        ? reply.raw.replaceAll('>', '').trim()
        : 'ERROR: ${reply.completion.toUpperCase()}\n${reply.raw}';
  }

  Future<bool> _waitForSynchronization() async {
    if (!isConnected) return false;
    if (_serialSynchronized) return _pendingWrite == null;
    final sw = Stopwatch()..start();
    _transportEvent('drain_wait_start', {'limit_ms': 500});
    try {
      await _drained?.future.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      // One bounded passive drain, never an interrupt/reset/repeated PID.
    }
    final ok = _serialSynchronized && _pendingWrite == null && isConnected;
    _transportEvent('drain_wait_end', {
      'elapsed_ms': sw.elapsedMilliseconds,
      'synchronized': ok,
      'write_pending': _pendingWrite != null,
      'completion': ok ? 'prompt' : 'unsynchronized_not_sent',
    });
    return ok;
  }

  Future<ElmReply> _exchange(
    String command, {
    Duration timeout = const Duration(milliseconds: 1200),
    bool restoring = false,
    bool waitForSync = true,
  }) async {
    if (timeout > const Duration(seconds: 5)) {
      timeout = const Duration(seconds: 5);
    }
    final ownsSequence =
        _sequenceOwner != null && Zone.current[_sequenceKey] == _sequenceOwner;
    if ((_isDeepScanning || _sequenceOwner != null) && !ownsSequence) {
      return ElmReply('', 'busy_transaction');
    }
    while (_cmdQueue != null) {
      await _cmdQueue!.future;
    }
    if ((_isDeepScanning || _sequenceOwner != null) && !ownsSequence) {
      return ElmReply('', 'busy_transaction');
    }
    final done = Completer<void>();
    _cmdQueue = done;
    final sw = Stopwatch()..start();
    final started = DateTime.now();
    final id = ++_transactionSequence;
    final stats = <String, dynamic>{
      'transaction_id': id,
      'start_us': _journal.nowUs,
      'deadline_us': _journal.nowUs + timeout.inMicroseconds,
      'timeout_ms': timeout.inMilliseconds,
      'mtu': _observedMtu,
      'write_attempted': false,
      'write_completed': false,
      'first_rx_us': null,
      'last_rx_us': null,
      'rx_byte_count': 0,
      'rx_notification_count': 0,
      'prompt_us': null,
    };
    ElmReply finish(String raw, String completion) {
      final details = Map<String, dynamic>.from(stats);
      _transportEvent('exchange_end', {
        ...details,
        'command': command,
        'completion': completion,
        'elapsed_ms': sw.elapsedMilliseconds,
        'response_byte_length': raw.length,
      });
      return ElmReply(
        raw,
        completion,
        time: started,
        elapsedMs: sw.elapsedMilliseconds,
        transport: details,
      );
    }

    _transportEvent('exchange_attempt', {...stats, 'command': command});
    try {
      if (_cancelDeepScanRequested &&
          ownsSequence &&
          !restoring &&
          !_isPollingBusy) {
        return finish('', 'cancelled');
      }
      if (!isConnected &&
          currentTelemetry.status != ObdConnectionStatus.initializing) {
        return finish('', 'disconnected');
      }
      if (!_serialSynchronized) {
        final synchronized = waitForSync && await _waitForSynchronization();
        if (!synchronized) {
          return finish(_rxBuffer.toString(), 'unsynchronized_not_sent');
        }
      }
      // Future.timeout does not cancel the native write. Fence it until it actually settles.
      if (_pendingWrite != null) return finish('', 'write_pending_not_sent');
      final writeBudget = timeout - sw.elapsed;
      if (writeBudget <= Duration.zero) return finish('', 'deadline_not_sent');
      _rxBuffer.clear();
      _trailingRx.clear();
      _replyPromptSeen = false;
      _activeInterrupted = false;
      _transactionId = id;
      _exchangeStats = stats;
      final complete = Completer<String>();
      _cmdCompleter = complete;
      final data = ascii.encode('${command.trim()}\r');
      _invalidateAdapterState(command);
      stats['write_attempted'] = true;
      stats['write_start_us'] = _journal.nowUs;
      final w = _writeCharacteristic;
      _transportEvent('write_start', {
        'raw_hex': ElmObdParser.hex(data),
        'length': data.length,
        'deadline_us': stats['deadline_us'],
        'mtu': _observedMtu,
        'write_mode': _testWriter != null
            ? 'fake'
            : w?.properties.writeWithoutResponse == true
            ? 'without_response'
            : 'with_response',
        'write_supported': w?.properties.write,
        'write_without_response_supported': w?.properties.writeWithoutResponse,
        'service_uuid': w?.serviceUuid.str128,
        'write_characteristic_uuid': w?.uuid.str128,
      });
      try {
        if (_testWriter == null && w == null) return finish('', 'disconnected');
        final operation = _testWriter != null
            ? _testWriter!(data)
            : w!.write(
                data,
                withoutResponse: w.properties.writeWithoutResponse,
              );
        _pendingWrite = operation;
        unawaited(
          operation.then(
            (_) {
              if (identical(_pendingWrite, operation)) _pendingWrite = null;
              stats['write_completed'] = true;
              stats['write_end_us'] = _journal.nowUs;
              _transportEvent('write_complete', {'transaction_id': id});
            },
            onError: (Object error, StackTrace stack) {
              if (identical(_pendingWrite, operation)) _pendingWrite = null;
              _transportEvent('write_failed', {
                'transaction_id': id,
                'error_type': error.runtimeType.toString(),
              });
            },
          ),
        );
        await operation.timeout(writeBudget);
        final protectionBudget = timeout - sw.elapsed;
        if (protectionBudget > Duration.zero) {
          await Future<void>.delayed(
            protectionBudget < const Duration(milliseconds: 25)
                ? protectionBudget
                : const Duration(milliseconds: 25),
          );
        }
        final remaining = timeout - sw.elapsed;
        if (remaining <= Duration.zero) throw TimeoutException('write timeout');
        final raw = await complete.future.timeout(remaining);
        final completion = raw.endsWith('>')
            ? 'prompt'
            : (!isConnected ? 'disconnected' : 'cancelled');
        if (completion != 'prompt' && !_activeInterrupted) {
          _markUnsynchronized();
        }
        final reply = finish(raw, completion);
        if (reply.complete &&
            (_atOk(command, reply) ||
                RegExp(
                  r'^AT(Z|WS|D)$',
                ).hasMatch(command.trim().toUpperCase()))) {
          _recordAdapterState(command);
        }
        return reply;
      } on TimeoutException {
        _markUnsynchronized();
        return finish(_rxBuffer.toString(), 'timeout');
      } catch (e) {
        _markUnsynchronized();
        return finish(_rxBuffer.toString(), 'write_error: ${e.runtimeType}');
      } finally {
        _cmdCompleter = null;
      }
    } finally {
      _cmdQueue = null;
      done.complete();
    }
  }

  void _markUnsynchronized() {
    _serialSynchronized = false;
    _drained ??= Completer<void>();
    diagnosticStateNotifier.value = '串口未同步，等待旧响应结束';
  }

  void _markSynchronized() {
    _serialSynchronized = true;
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
  }

  String _atContent(String command, ElmReply reply) => reply.raw
      .replaceAll('>', '')
      .split(RegExp(r'[\r\n]+'))
      .where(
        (l) =>
            l.trim().isNotEmpty &&
            l.replaceAll(' ', '').toUpperCase() !=
                command.replaceAll(' ', '').toUpperCase(),
      )
      .map((l) => l.trim())
      .join('\n');

  bool _atOk(String command, ElmReply reply) =>
      reply.complete &&
      reply.raw
              .replaceAll('>', '')
              .split(RegExp(r'[\r\n]+'))
              .where(
                (l) =>
                    l.trim().isNotEmpty &&
                    l.replaceAll(' ', '').toUpperCase() !=
                        command.replaceAll(' ', '').toUpperCase(),
              )
              .map((l) => l.trim().toUpperCase())
              .join() ==
          'OK';

  void _invalidateAdapterState(String command) {
    // An unacknowledged write may have changed adapter state. Never retain a stale ACK.
    final cmd = command.replaceAll(' ', '').toUpperCase();
    if (cmd.startsWith('ATSH')) _knownHeader = null;
    if (RegExp(r'^ATH[01]$').hasMatch(cmd)) _knownDisplay = null;
    if (RegExp(r'^ATCAF[01]$').hasMatch(cmd)) _knownFormatting = null;
    if (cmd.startsWith('ATSP') || cmd.startsWith('ATTP')) {
      _knownProtocol = null;
      _knownHeader = null;
    }
    if (cmd == 'ATD' || cmd == 'ATZ' || cmd == 'ATWS') {
      _knownHeader = null;
      _knownDisplay = null;
      _knownFormatting = null;
      _knownProtocol = null;
    }
  }

  void _recordAdapterState(String command) {
    final cmd = command.replaceAll(' ', '').toUpperCase();
    if (cmd.startsWith('ATSH')) _knownHeader = cmd.substring(4);
    if (RegExp(r'^ATH[01]$').hasMatch(cmd)) _knownDisplay = cmd;
    if (cmd.startsWith('ATSP')) _knownProtocol = cmd;
    if (RegExp(r'^ATCAF[01]$').hasMatch(cmd)) _knownFormatting = cmd;
    if (cmd == 'ATD' || cmd == 'ATZ' || cmd == 'ATWS') {
      _knownHeader = null;
      _knownDisplay = null;
      _knownProtocol = null;
      _knownFormatting = null;
    }
  }

  void _onDataReceived(List<int> data) {
    final now = _journal.nowUs;
    final late =
        !_serialSynchronized || _replyPromptSeen || _cmdCompleter == null;
    final stats = _exchangeStats;
    if (stats != null) {
      stats['first_rx_us'] ??= now;
      stats['last_rx_us'] = now;
      stats['rx_byte_count'] = (stats['rx_byte_count'] as int) + data.length;
      stats['rx_notification_count'] =
          (stats['rx_notification_count'] as int) + 1;
    }
    _transportEvent('rx_notification', {
      'notification_seq': ++_notificationSequence,
      'received_us': now,
      'raw_hex': ElmObdParser.hex(data),
      'length': data.length,
      'late': late,
      'mtu': _observedMtu,
    });
    if (data.isEmpty) return;
    // Latin-1 is byte-preserving. Non-ASCII input fails parser validation, never replaced.
    final text = latin1.decode(data);
    if (_replyPromptSeen) {
      _receiveTrailing(text);
      return;
    }
    if (late && _scanOwnsSerial) {
      _scanLateReplies.add({
        'phase': 'late_fragment',
        'transaction_id': _transactionId,
        'mono_us': now,
        'raw_hex': ElmObdParser.hex(data),
        'length': data.length,
      });
    }
    final prompt = text.indexOf('>');
    _rxBuffer.write(prompt < 0 ? text : text.substring(0, prompt + 1));
    if (prompt < 0) return;
    _replyPromptSeen = true;
    stats?['prompt_us'] = now;
    _transportEvent(late ? 'late_prompt' : 'prompt', {
      'offset_in_notification': prompt,
    });
    if (!_serialSynchronized) {
      if (_scanOwnsSerial) {
        _scanLateReplies.add({
          'phase': 'late_reply_drain',
          'transaction_id': _transactionId,
          'raw': _rxBuffer.toString(),
          'mono_us': now,
          'reason':
              'previous interrupted exchange; not assigned to another PID',
        });
      }
      _markSynchronized();
    }
    final c = _cmdCompleter;
    if (c != null && !c.isCompleted) c.complete(_rxBuffer.toString());
    if (prompt + 1 < text.length) _receiveTrailing(text.substring(prompt + 1));
  }

  void _receiveTrailing(String text) {
    if (RegExp(r'^[ \r\n\t]*$').hasMatch(text) && _trailingRx.isEmpty) return;
    _trailingRx.write(text);
    _markUnsynchronized();
    _transportEvent('unassigned_fragment', {
      'raw_hex': ElmObdParser.hex(latin1.encode(text)),
      'length': text.length,
    });
    final all = _trailingRx.toString();
    final prompt = all.lastIndexOf('>');
    if (prompt >= 0) {
      final remainder = all.substring(prompt + 1);
      _transportEvent('unassigned_prompt', {'drained_byte_length': prompt + 1});
      _trailingRx.clear();
      if (RegExp(r'^[ \r\n\t]*$').hasMatch(remainder)) {
        _markSynchronized();
      } else {
        _trailingRx.write(remainder);
      }
    }
  }

  // --- 7. 连接断开与清理 ---
  void _handleDisconnection() {
    _pollingTimer?.cancel();
    _transportEvent('disconnect');
    _serialSynchronized = false;
    final drained = _drained;
    _drained = null;
    if (drained != null && !drained.isCompleted) drained.complete();
    diagnosticStateNotifier.value = '连接已断开';
    _cancelDeepScanRequested = _isDeepScanning;
    if (_cmdCompleter != null && !_cmdCompleter!.isCompleted) {
      _activeInterrupted = true;
      _markUnsynchronized();
      _cmdCompleter!.complete(_rxBuffer.toString());
    }
    _knownHeader = null;
    _knownDisplay = null;
    _knownProtocol = null;
    _knownFormatting = null;
    _updateStatus(ObdConnectionStatus.disconnected, message: '蓝牙连接已断开');
    log('🔌 OBD 蓝牙链路已终止');
  }

  Future<void> disconnect() async {
    _handleDisconnection();
    _pollingTimer?.cancel();
    _notifySubscription?.cancel();
    _mtuSubscription?.cancel();
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
      if (_cmdCompleter != null &&
          !_cmdCompleter!.isCompleted &&
          _scanOwnsSerial &&
          !_restoringScanState) {
        _activeInterrupted = true;
        _markUnsynchronized();
        _cmdCompleter!.complete(_rxBuffer.toString());
      }
      log('⚠️ 用户请求终止全车深度扫描');
    }
  }

  Future<ObdDeepScanReport?> runDeepScan({
    ObdScanModule module = ObdScanModule.basic,
    void Function(double progress, String status, ObdDiscoveredItem? newItem)?
    onProgress,
  }) async {
    if (!isConnected || _isDeepScanning) return null;
    _isDeepScanning =
        true; // Reserve before waiting for any in-flight sequence.
    _cancelDeepScanRequested = false;
    isDeepScanningNotifier.value = true;
    _pollingTimer?.cancel();
    try {
      return await _sequence(() => _runDeepScanOwned(module, onProgress));
    } finally {
      _isDeepScanning = false;
      _cancelDeepScanRequested = false;
      isDeepScanningNotifier.value = false;
      _startPolling();
    }
  }

  Future<ObdDeepScanReport> _runDeepScanOwned(
    ObdScanModule module,
    void Function(double, String, ObdDiscoveredItem?)? onProgress,
  ) async {
    // The sequence lock drains polling; drain a manual command that preceded it too.
    while (_cmdQueue != null) {
      await _cmdQueue!.future;
    }
    _scanOwnsSerial = true;
    _scanLateReplies.clear();
    _journal.beginCapture();
    _transportEvent('capture_start', {'mtu': _observedMtu});
    final start = DateTime.now();
    final probes = _buildProbeList(module);
    final items = <ObdDiscoveredItem>[];
    final ecus = <String>{};
    final trace = <Map<String, dynamic>>[];
    final savedHeader = _knownHeader;
    final savedDisplay = _knownDisplay;
    final savedProtocol = _knownProtocol;
    final savedFormatting = _knownFormatting;
    var protocol = 'unknown';
    var outcome = 'completed';
    var touched = false;
    var restored = true;
    void progress(double p, String status, ObdDiscoveredItem? item) {
      // A disposed/debug UI must not abort restoration or discard evidence.
      try {
        onProgress?.call(p, status, item);
      } catch (e) {
        log('扫描进度显示异常: $e');
      }
    }

    Future<ElmReply> exchange(String cmd, {bool restoring = false}) async {
      final r = await _exchange(
        cmd,
        timeout: const Duration(milliseconds: 1400),
        restoring: restoring,
        waitForSync: !restoring,
      );
      trace.add({
        'command': cmd,
        'phase': restoring ? 'restore' : 'scan',
        'request_header': _knownHeader ?? 'unknown',
        ...r.toJson(),
      });
      return r;
    }

    Future<void> setting(String cmd) async {
      final r = await exchange(cmd);
      if (!_atOk(cmd, r)) {
        throw StateError('adapter_setting_failed: $cmd (${r.completion})');
      }
    }

    try {
      trace.add({
        'phase': 'snapshot',
        'header': savedHeader ?? 'unknown',
        'display': savedDisplay ?? 'unknown',
        'protocol_setting': savedProtocol ?? 'unknown',
        'CAN_formatting': savedFormatting ?? 'unknown',
        'module': module.name,
        'planned_probe_count': probes.length,
        'scope': module.scope,
      });
      if (_cancelDeepScanRequested) {
        outcome = isConnected ? 'cancelled' : 'disconnected';
      } else {
        final dp = await exchange('ATDP');
        if (dp.complete) protocol = _atContent('ATDP', dp);
        if (!dp.complete) throw StateError('protocol_query_incomplete');
        // Scan profile uses 11-bit CAN addressing. Do not silently change a manual protocol.
        final dpn = await exchange('ATDPN');
        final number = _atContent('ATDPN', dpn).toUpperCase();
        if (!dpn.complete || (number != '6' && number != 'A6')) {
          throw StateError('scan_requires_CAN_11bit_500k; observed $number');
        }
        touched = true;
        await setting('ATSH7DF');
        await setting('ATH1');
        await setting('ATCAF1');
        if (module.discoversEcus) {
          progress(0.02, '显式 0100 响应节点发现（不是全部 ECU 遍历）', null);
          final discovery = await exchange('0100');
          final classified = ElmObdParser.classify(discovery, '0100');
          trace.add({
            'phase': 'ECU_discovery',
            'reason': classified.reason,
            'frames': classified.frames.map((f) => f.toJson()).toList(),
          });
          ecus.addAll(
            classified.frames
                .where((f) => f.positive && f.ecu != 'unknown')
                .map((f) => f.ecu),
          );
          if (!discovery.complete) {
            throw StateError('discovery_${discovery.completion}');
          }
        }
        for (final probe in probes) {
          if (_cancelDeepScanRequested || !isConnected) {
            outcome = isConnected ? 'cancelled' : 'disconnected';
            break;
          }
          final header = probe.header ?? '7DF';
          // Always explicit, including broadcast probes after a physical target.
          final h = await exchange('ATSH$header');
          ElmReply r;
          ObdResponseEvidence evidence;
          if (!_atOk('ATSH$header', h)) {
            r = ElmReply(
              '',
              'not_sent_header_failed',
              time: h.time,
              elapsedMs: h.elapsedMs,
            );
            evidence = ObdResponseEvidence(
              const [],
              'header_setting_failed (see trace)',
            );
          } else {
            r = await exchange(probe.cmd);
            evidence = _classifyProbe(r, probe);
          }
          final candidate =
              module == ObdScanModule.fuel ||
              probe.cmd.startsWith('21') ||
              probe.cmd.startsWith('22');
          String? hint;
          if (!candidate && evidence.positive) {
            // Decode only a complete matched payload from one ECU, never joined frames/ECUs.
            final payload = evidence.frames
                .firstWhere((f) => f.positive)
                .payload;
            hint = _formatSampleValue(probe.cmd, payload);
          }
          final item = ObdDiscoveredItem(
            category: probe.category,
            header: header,
            command: probe.cmd,
            name: probe.name,
            rawHexResponse: r.raw,
            decodedHint: hint,
            responseTimeMs: r.elapsedMs,
            isSupported: evidence.positive,
            reason: evidence.reason,
            completion: r.completion,
            time: r.time,
            frames: evidence.frames,
            candidate: candidate,
            transport: r.transport,
            candidateExplanation: probe.explanation,
            expectedResponseEcu: probe.expectedEcu,
          );
          items.add(item);
          ecus.addAll(
            evidence.frames
                .where((f) => f.positive && f.ecu != 'unknown')
                .map((f) => f.ecu),
          );
          progress(
            items.length / probes.length,
            '已测 ${items.length}/${probes.length}；匹配响应 ${items.where((i) => i.isSupported).length}',
            item,
          );
          if (!r.complete) {
            outcome = !isConnected
                ? 'disconnected'
                : _cancelDeepScanRequested
                ? 'cancelled'
                : 'incomplete_transport';
            break; // No blind retry or further PID after an ambiguous exchange.
          }
        }
      }
    } catch (e) {
      outcome = _cancelDeepScanRequested
          ? (!isConnected ? 'disconnected' : 'cancelled')
          : 'error';
      trace.add({'phase': 'error', 'reason': e.toString()});
    } finally {
      _restoringScanState = true;
      // Decide synchronization once for the whole restoration transaction.
      final drainStarted = DateTime.now();
      final drainWatch = Stopwatch()..start();
      final synchronized = await _waitForSynchronization();
      trace.add({
        'phase': 'restore_sync',
        'time': drainStarted.toIso8601String(),
        'elapsed_ms': drainWatch.elapsedMilliseconds,
        'completion': synchronized ? 'prompt' : 'unsynchronized_not_sent',
        'write_attempted': false,
      });
      if (touched) {
        trace.add({
          'phase': 'restore_plan',
          'protocol': 'unchanged_by_scan',
          'CAN_formatting_origin': savedFormatting == null
              ? 'unknown; no fallback'
              : 'observed ACK',
          'header_origin': savedHeader == null
              ? 'unknown; no fallback'
              : 'observed ACK',
          'display_origin': savedDisplay == null
              ? 'unknown; no fallback'
              : 'observed ACK',
        });
        final settings = <String, String?>{
          'CAN_formatting': savedFormatting,
          'header': savedHeader == null ? null : 'ATSH$savedHeader',
          'display': savedDisplay,
        };
        for (final entry in settings.entries) {
          final cmd = entry.value;
          if (cmd == null ||
              !isConnected ||
              !synchronized ||
              !_serialSynchronized ||
              _pendingWrite != null) {
            restored = false;
            trace.add({
              'phase': 'restore',
              'setting': entry.key,
              'command': cmd,
              'completion': cmd == null
                  ? 'unknown_original_not_restored'
                  : !isConnected
                  ? 'not_sent_disconnected'
                  : 'unsynchronized_not_sent',
              'write_attempted': false,
              'elapsed_ms': 0,
            });
            continue;
          }
          try {
            final r = await exchange(cmd, restoring: true);
            final ok = _atOk(cmd, r);
            trace.add({
              'phase': 'restore_result',
              'command': cmd,
              'acknowledged': ok,
            });
            if (!ok) restored = false;
          } catch (e) {
            restored = false;
            trace.add({
              'phase': 'restore',
              'command': cmd,
              'completion': 'restore_error',
            });
          }
        }
      }
      _pollingSuspended =
          !restored || !_serialSynchronized || _pendingWrite != null;
      if (outcome == 'completed' && _pollingSuspended) {
        outcome = 'completed_restore_unconfirmed';
      }
      diagnosticStateNotifier.value = _pollingSuspended
          ? '诊断已暂停：串口未同步或原状态恢复未确认'
          : '串口已同步，原状态恢复已确认';
      _transportEvent('capture_end', {
        'polling_suspended': _pollingSuspended,
        'synchronized': _serialSynchronized,
        'restoration_acknowledged': touched ? restored : null,
      });
      trace.addAll(_scanLateReplies);
      _scanLateReplies.clear();
      _scanOwnsSerial = false;
      _restoringScanState = false;
      trace.add({
        'phase': 'final',
        'restoration_acknowledged': touched ? restored : null,
        'polling_suspended': _pollingSuspended,
        'connected': isConnected,
      });
    }
    final transportEvents = _journal.endCapture();
    await _journal.flush();
    if (_journal.storageFailures > 0) {
      diagnosticStateNotifier.value += '；私有日志未完整保存，请查看报告';
    }
    final report = ObdDeepScanReport(
      startTime: start,
      module: module,
      transportEvents: transportEvents,
      transportStorage: {
        ..._journal.storageStatus,
        'capture_end_event': transportEvents.isEmpty
            ? null
            : transportEvents.last['event_seq'],
      },
      endTime: DateTime.now(),
      deviceName: connectedDeviceName ?? 'unknown',
      protocolName: protocol,
      activeEcus: ecus.toList()..sort(),
      items: items,
      totalTested: items.length,
      totalSupported: items.where((i) => i.isSupported).length,
      outcome: outcome,
      trace: trace,
    );
    lastDeepScanReportNotifier.value = report;
    log(
      '扫描结束: $outcome；已测 ${items.length}；匹配响应 ${report.totalSupported}；恢复确认 ${touched ? restored : '未执行（未改状态）'}',
    );
    return report;
  }

  String? _formatSampleValue(String cmd, String raw) {
    if (cmd == '0104' || cmd == '012F') {
      final p = _parsePercent(raw);
      if (p != null) return '${p.toStringAsFixed(1)}%';
    } else if (cmd == '010F') {
      final t = _parseStandardTemp(raw);
      if (t != null) return '${t.toStringAsFixed(1)} °C';
    } else if (cmd == '010D') {
      final s = _parseStandardSpeed(raw);
      if (s != null) return '${s.toInt()} km/h (车速)';
    } else if (cmd == '010C') {
      final r = _parseStandardRpm(raw);
      if (r != null) return '${r.toInt()} rpm (转速)';
    } else if (cmd == '0105') {
      final c = _parseStandardTemp(raw);
      if (c != null) return '${c.toInt()} °C (水温)';
    } else if (cmd == '0142') {
      final v = _parseStandardModuleVoltage(raw);
      if (v != null) return '${v.toStringAsFixed(2)} V (控制模块供电)';
    } else if (cmd == '01A6') {
      final odo = _parseStandardOdometer(raw);
      if (odo != null) return '${odo.toStringAsFixed(1)} km (仪表累计总里程)';
    } else if (cmd == '015C') {
      final c = _parseStandardTemp(raw);
      if (c != null) return '${c.toInt()} °C (发动机机油温)';
    } else if (cmd == '0111') {
      final p = _parsePercent(raw);
      if (p != null) return '${p.toStringAsFixed(1)}% (节气门开度)';
    } else if (cmd == '0149') {
      final p = _parsePercent(raw);
      if (p != null) return '${p.toStringAsFixed(1)}% (油门踏板D)';
    } else if (cmd == '014A') {
      final p = _parsePercent(raw);
      if (p != null) return '${p.toStringAsFixed(1)}% (油门踏板E)';
    } else if (cmd == '0110') {
      final m = _parseStandardMaf(raw);
      if (m != null) return '${m.toStringAsFixed(2)} g/s (进气空气流量)';
    } else if (cmd == '0133') {
      final b = _parseStandardBaro(raw);
      if (b != null) return '${b.toInt()} kPa (大气压强)';
    } else if (cmd == '013C') {
      final t = _parseStandardCatTemp(raw);
      if (t != null) return '${t.toStringAsFixed(1)} °C (催化转化器温1)';
    } else if (cmd == '013D') {
      final t = _parseStandardCatTemp(raw);
      if (t != null) return '${t.toStringAsFixed(1)} °C (催化转化器温2)';
    } else if (cmd == '0106') {
      final val = _parseFuelTrim(raw);
      if (val != null) return '${val.toStringAsFixed(1)}% (短期燃油修正 STFT)';
    } else if (cmd == '0107') {
      final val = _parseFuelTrim(raw);
      if (val != null) return '${val.toStringAsFixed(1)}% (长期燃油修正 LTFT)';
    } else if (cmd == '010E') {
      final val = _parseTimingAdvance(raw);
      if (val != null) return '${val.toStringAsFixed(1)}° (点火提前角)';
    } else if (cmd == '011F') {
      final s = _parseRunTime(raw);
      if (s != null) return '$s s (本次运行时间)';
    } else if (cmd == '0134') {
      final lambda = _parseLambda(raw);
      if (lambda != null) return '${lambda.toStringAsFixed(3)} λ (空燃比当量比)';
    } else if (cmd == '0145') {
      final p = _parsePercent(raw);
      if (p != null) return '${p.toStringAsFixed(1)}% (相对节气门开度)';
    } else if (cmd == '0146') {
      final c = _parseStandardTemp(raw);
      if (c != null) return '${c.toInt()} °C (车外环境温度)';
    } else if (cmd == '014C') {
      final p = _parsePercent(raw);
      if (p != null) return '${p.toStringAsFixed(1)}% (节气门作动器指令)';
    }
    return null;
  }

  ObdResponseEvidence _classifyProbe(ElmReply reply, _ProbeEntry probe) {
    final original = ElmObdParser.classify(reply, probe.cmd);
    final frames = original.frames.map((frame) {
      String? failure;
      if ((frame.positive || frame.service != null) &&
          probe.expectedEcu != null &&
          frame.ecu != probe.expectedEcu) {
        failure = 'unexpected_response_ecu';
      } else if (frame.positive &&
          probe.payloadBytes != null &&
          frame.payload.length != probe.payloadBytes! * 2) {
        failure = 'unexpected_payload_length';
      }
      if (failure == null) return frame;
      return ObdFrameEvidence(
        frame.ecu,
        frame.payload,
        failure,
        service: frame.service,
        nrc: frame.nrc,
        structureVerdict: failure,
        transportCompletion: reply.completion,
      );
    }).toList();
    final contractMismatch =
        probe.payloadBytes != null &&
        frames.any(
          (f) => const {
            'unexpected_response_ecu',
            'unexpected_payload_length',
            'wrong_service_or_pid',
          }.contains(f.verdict),
        );
    if (contractMismatch) {
      for (var i = 0; i < frames.length; i++) {
        final frame = frames[i];
        if (frame.positive) {
          frames[i] = ObdFrameEvidence(
            frame.ecu,
            frame.payload,
            'candidate_contract_mismatch',
            structureVerdict: frame.structureVerdict,
            transportCompletion: reply.completion,
          );
        }
      }
    }
    return ObdResponseEvidence(
      frames,
      frames.any((f) => f.positive)
          ? 'matched_response'
          : frames.map((f) => f.verdict).toSet().join(', '),
    );
  }

  List<_ProbeEntry> _buildProbeList(ObdScanModule module) {
    if (module == ObdScanModule.fuel) {
      // Community definitions are request/layout candidates, never vehicle proof or formulas.
      return const [
        _ProbeEntry(
          '油量候选',
          '7DF',
          '012F',
          '标准液位百分比（待验证）',
          payloadBytes: 3,
          explanation: '标准液位候选；仅记录本次响应，不将百分比折算成升数。',
        ),
        _ProbeEntry(
          '油量候选',
          '7C0',
          '221022',
          '仪表油量 DID（社区候选）',
          expectedEcu: '7C8',
          payloadBytes: 5,
          explanation: 'OBDb Yaris候选：预期7C8及62 10 22加2字节；本车含义/有效值未验证，不换算或赋正式升数。',
        ),
        _ProbeEntry(
          '油量候选',
          '7C0',
          '2129',
          '仪表油量 PID（社区候选）',
          expectedEcu: '7C8',
          payloadBytes: 3,
          explanation: 'OBDb Yaris候选：预期7C8及61 29加1字节；倍率未在本车验证，不套其他车型公式。',
        ),
      ];
    }
    return _allProbeCandidates()
        .where(
          (p) =>
              p.cmd.startsWith('09') == (module == ObdScanModule.vehicleInfo),
        )
        .toList();
  }

  List<_ProbeEntry> _allProbeCandidates() {
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

      // 3. 丰田 TNGA 第四代 THS-II 混动核心 (Header 0x7E2 / 0x7EB)
      _ProbeEntry('TNGA混动', '7E2', '221024', 'TNGA 电池遥测 (SOC, VB, IB, 充放功率)'),
      _ProbeEntry(
        'TNGA混动',
        '7E2',
        '221100',
        'TNGA 升压与逆变器温 (VL, VH, MG1/MG2, 油温)',
      ),
      _ProbeEntry(
        'TNGA混动',
        '7E2',
        '221102',
        'TNGA 双电机与再生力矩 (MG1/MG2 RPM, MG2/再生扭矩)',
      ),
      _ProbeEntry('TNGA电池', '7EB', '222884', 'TNGA 电芯极值 (最高单体, 最低单体, 压差)'),
      _ProbeEntry(
        'TNGA电池',
        '7EB',
        '222885',
        'TNGA 电池包 6 点温感监控 (Pack Temperatures)',
      ),
      _ProbeEntry(
        'TNGA混动',
        '7E2',
        '222006',
        'UDS 混动系统记录里程 (HV Total Odometer)',
      ),
      _ProbeEntry(
        'TNGA混动',
        '7E2',
        '220101',
        'UDS 混动电池包扩充遥测 (Battery Pack Ext)',
      ),
      _ProbeEntry('TNGA混动', '7E2', '21C3', '兼容旧版混动矩阵 (Legacy Prius 21C3)'),
      _ProbeEntry('TNGA混动', '7E2', '21C4', '兼容旧版升压变压器 (Legacy Prius 21C4)'),

      // 4. 丰田 TNGA 发动机 ECM (Header 0x7E0)
      _ProbeEntry('TNGA发动机', '7E0', '221234', '电子冷却水泵实际/目标转速与机油温'),
      _ProbeEntry('TNGA发动机', '7E0', '222006', 'ECM 记录总里程 (ECM Total Odometer)'),
      _ProbeEntry(
        'TNGA发动机',
        '7E0',
        '222008',
        '累计燃油消耗总量 (Total Fuel Consumed L)',
      ),
      _ProbeEntry('TNGA发动机', '7E0', '21CE', '兼容旧版机油温度与压力 (Legacy ECM 21CE)'),
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
          if (cUuid.contains('fff2') ||
              (props.write || props.writeWithoutResponse)) {
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
          if (cUuid.contains('6e400002') &&
              (props.write || props.writeWithoutResponse)) {
            w = c;
          } else if (cUuid.contains('6e400003') &&
              (props.notify || props.indicate)) {
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
          if ((cUuid.contains('1e4d') ||
                  props.write ||
                  props.writeWithoutResponse) &&
              w == null) {
            if (props.write || props.writeWithoutResponse) w = c;
          }
          if ((cUuid.contains('8841') || props.notify || props.indicate) &&
              n == null) {
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
          if (cUuid.contains('ffe1') ||
              (props.write || props.writeWithoutResponse)) {
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
  ObdGattChannel? resolveObdGattChannelForTesting(
    List<BluetoothService> services,
  ) => _resolveObdGattChannel(services);

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
  double? parseStandardModuleVoltage(String resp) =>
      _parseStandardModuleVoltage(resp);

  @visibleForTesting
  double? parseStandardOdometer(String resp) => _parseStandardOdometer(resp);

  @visibleForTesting
  double? parseStandardMaf(String resp) => _parseStandardMaf(resp);

  @visibleForTesting
  double? parseStandardBaro(String resp) => _parseStandardBaro(resp);

  @visibleForTesting
  double? parseStandardCatTemp(String resp) => _parseStandardCatTemp(resp);

  @visibleForTesting
  void parseToyotaTnga221024ForTesting(String resp) =>
      _parseToyotaTnga221024(resp);

  @visibleForTesting
  void parseToyotaTnga221100ForTesting(String resp) =>
      _parseToyotaTnga221100(resp);

  @visibleForTesting
  void parseToyotaTnga222884ForTesting(String resp) =>
      _parseToyotaTnga222884(resp);

  @visibleForTesting
  void parseToyotaTnga222885ForTesting(String resp) =>
      _parseToyotaTnga222885(resp);

  @visibleForTesting
  void parseToyotaTnga221234ForTesting(String resp) =>
      _parseToyotaTnga221234(resp);

  @visibleForTesting
  double? parseFuelTrim(String resp) => _parseFuelTrim(resp);

  @visibleForTesting
  double? parseTimingAdvance(String resp) => _parseTimingAdvance(resp);

  @visibleForTesting
  int? parseRunTime(String resp) => _parseRunTime(resp);

  @visibleForTesting
  double? parseLambda(String resp) => _parseLambda(resp);

  @visibleForTesting
  void parseToyotaTnga221102ForTesting(String resp) =>
      _parseToyotaTnga221102(resp);

  @visibleForTesting
  void parseToyotaTnga222006ForTesting(String resp) =>
      _parseToyotaTnga222006(resp);

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
  final String? expectedEcu;
  final int? payloadBytes;
  final String? explanation;

  const _ProbeEntry(
    this.category,
    this.header,
    this.cmd,
    this.name, {
    this.expectedEcu,
    this.payloadBytes,
    this.explanation,
  });
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
