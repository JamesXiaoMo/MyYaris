import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:my_yaris/services/car_obd_service.dart';

class MockBluetoothCharacteristic implements BluetoothCharacteristic {
  @override
  final Guid characteristicUuid;
  @override
  final CharacteristicProperties properties;
  @override
  final Guid serviceUuid;
  @override
  final DeviceIdentifier remoteId = DeviceIdentifier('00:11:22:33:44:55');

  MockBluetoothCharacteristic({
    required this.characteristicUuid,
    required this.properties,
    required this.serviceUuid,
  });

  @override
  Guid get uuid => characteristicUuid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MockBluetoothService implements BluetoothService {
  @override
  final Guid serviceUuid;
  @override
  final List<BluetoothCharacteristic> characteristics;
  @override
  final DeviceIdentifier remoteId = DeviceIdentifier('00:11:22:33:44:55');

  MockBluetoothService({
    required this.serviceUuid,
    required this.characteristics,
  });

  @override
  Guid get uuid => serviceUuid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CharacteristicProperties createProps({
  bool write = false,
  bool writeWithoutResponse = false,
  bool notify = false,
  bool indicate = false,
  bool read = false,
}) {
  return CharacteristicProperties(
    broadcast: false,
    read: read,
    writeWithoutResponse: writeWithoutResponse,
    write: write,
    notify: notify,
    indicate: indicate,
    authenticatedSignedWrites: false,
    extendedProperties: false,
    notifyEncryptionRequired: false,
    indicateEncryptionRequired: false,
  );
}

void main() {
  group('CarObdService GATT Channel Resolution Tests', () {
    final obd = CarObdService();

    test('Veepeak FFF0 service is prioritized and NEVER selects Generic Access 0x1800 / 0x2A00', () {
      final s1800Uuid = Guid('00001800-0000-1000-8000-00805f9b34fb');
      final genericAccess = MockBluetoothService(
        serviceUuid: s1800Uuid,
        characteristics: [
          MockBluetoothCharacteristic(
            serviceUuid: s1800Uuid,
            characteristicUuid: Guid('00002a00-0000-1000-8000-00805f9b34fb'), // Device Name (writable)
            properties: createProps(write: true, read: true),
          ),
          MockBluetoothCharacteristic(
            serviceUuid: s1800Uuid,
            characteristicUuid: Guid('00002a01-0000-1000-8000-00805f9b34fb'), // Appearance
            properties: createProps(read: true),
          ),
        ],
      );

      final s1801Uuid = Guid('00001801-0000-1000-8000-00805f9b34fb');
      final genericAttr = MockBluetoothService(
        serviceUuid: s1801Uuid,
        characteristics: [
          MockBluetoothCharacteristic(
            serviceUuid: s1801Uuid,
            characteristicUuid: Guid('00002a05-0000-1000-8000-00805f9b34fb'), // Service Changed (indicate)
            properties: createProps(indicate: true),
          ),
        ],
      );

      final sFff0Uuid = Guid('0000fff0-0000-1000-8000-00805f9b34fb');
      final veepeakUart = MockBluetoothService(
        serviceUuid: sFff0Uuid,
        characteristics: [
          MockBluetoothCharacteristic(
            serviceUuid: sFff0Uuid,
            characteristicUuid: Guid('0000fff1-0000-1000-8000-00805f9b34fb'), // RX: Notify only
            properties: createProps(notify: true, read: true),
          ),
          MockBluetoothCharacteristic(
            serviceUuid: sFff0Uuid,
            characteristicUuid: Guid('0000fff2-0000-1000-8000-00805f9b34fb'), // TX: Write & WriteNoResp
            properties: createProps(write: true, writeWithoutResponse: true),
          ),
        ],
      );

      final channel = obd.resolveObdGattChannelForTesting([genericAccess, genericAttr, veepeakUart]);

      expect(channel, isNotNull);
      expect(channel!.profileName, equals('Veepeak/Vgate FFF0'));
      // 核心验证: 绝对不能选中 0x2A00 Device Name，必须锁定 FFF2 与 FFF1
      expect(channel.writeCharacteristic.uuid.str128.toLowerCase(), contains('fff2'));
      expect(channel.notifyCharacteristic.uuid.str128.toLowerCase(), contains('fff1'));
      expect(channel.writeCharacteristic.uuid.str128.toLowerCase(), isNot(contains('2a00')));
    });

    test('Nordic UART Service (NUS 6E400001) resolves write 6E400002 and notify 6E400003', () {
      final nusUuid = Guid('6e400001-b5a3-f393-e0a9-e50e24dcca9e');
      final nusService = MockBluetoothService(
        serviceUuid: nusUuid,
        characteristics: [
          MockBluetoothCharacteristic(
            serviceUuid: nusUuid,
            characteristicUuid: Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e'),
            properties: createProps(write: true, writeWithoutResponse: true),
          ),
          MockBluetoothCharacteristic(
            serviceUuid: nusUuid,
            characteristicUuid: Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e'),
            properties: createProps(notify: true),
          ),
        ],
      );

      final channel = obd.resolveObdGattChannelForTesting([nusService]);
      expect(channel, isNotNull);
      expect(channel!.profileName, equals('Nordic UART Service (NUS)'));
      expect(channel.writeCharacteristic.uuid.str128.toLowerCase(), contains('6e400002'));
      expect(channel.notifyCharacteristic.uuid.str128.toLowerCase(), contains('6e400003'));
    });

    test('Services with only standard SIG UUIDs return null', () {
      final s1800 = MockBluetoothService(
        serviceUuid: Guid('00001800-0000-1000-8000-00805f9b34fb'),
        characteristics: [
          MockBluetoothCharacteristic(
            serviceUuid: Guid('00001800-0000-1000-8000-00805f9b34fb'),
            characteristicUuid: Guid('00002a00-0000-1000-8000-00805f9b34fb'),
            properties: createProps(write: true),
          ),
        ],
      );
      final s180a = MockBluetoothService(
        serviceUuid: Guid('0000180a-0000-1000-8000-00805f9b34fb'),
        characteristics: [
          MockBluetoothCharacteristic(
            serviceUuid: Guid('0000180a-0000-1000-8000-00805f9b34fb'),
            characteristicUuid: Guid('00002a29-0000-1000-8000-00805f9b34fb'),
            properties: createProps(read: true),
          ),
        ],
      );

      final channel = obd.resolveObdGattChannelForTesting([s1800, s180a]);
      expect(channel, isNull);
    });
  });

  group('CarObdService Standard PID and AT Decoders', () {
    final obd = CarObdService();

    test('Standard Speed 010D parsing', () {
      expect(obd.parseStandardSpeed('41 0D 32'), equals(50.0));
      expect(obd.parseStandardSpeed('410D00'), equals(0.0));
      expect(obd.parseStandardSpeed('410D64'), equals(100.0));
      expect(obd.parseStandardSpeed('NO DATA'), isNull);
    });

    test('Standard RPM 010C parsing', () {
      // 010C: ((0x1F * 256) + 0x40) / 4 = 8000 / 4 = 2000.0 RPM
      expect(obd.parseStandardRpm('41 0C 1F 40'), equals(2000.0));
      // 010C: 0x0FA0 = 4000 -> 1000.0 RPM
      expect(obd.parseStandardRpm('410C0FA0'), equals(1000.0));
      expect(obd.parseStandardRpm('SEARCHING...'), isNull);
    });

    test('Standard Coolant Temp 0105 parsing', () {
      // 0105: 0x5B (91) - 40 = 51.0 °C
      expect(obd.parseStandardTemp('41 05 5B'), equals(51.0));
      // 0105: 0x78 (120) - 40 = 80.0 °C
      expect(obd.parseStandardTemp('410578'), equals(80.0));
      expect(obd.parseStandardTemp('UNABLE TO CONNECT'), isNull);
    });

    test('AT RV battery voltage parsing', () {
      expect(obd.parseAtRv('14.2V'), equals(14.2));
      expect(obd.parseAtRv('12.6 V\r>'), equals(12.6));
      expect(obd.parseAtRv('ERROR'), isNull);
    });

    test('Standard Percent 0111 / 0104 / 0149 / 014A parsing', () {
      // 0x80 (128) * 100 / 255 = ~50.196%
      final p = obd.parsePercent('41 11 80');
      expect(p, isNotNull);
      expect(p!, closeTo(50.19, 0.1));

      // 0149: 0x28 (40) * 100 / 255 = 15.686%
      final p49 = obd.parsePercent('414928');
      expect(p49, isNotNull);
      expect(p49!, closeTo(15.69, 0.1));

      // 014A: 0x51 (81) * 100 / 255 = 31.764%
      final p4a = obd.parsePercent('414A51');
      expect(p4a, isNotNull);
      expect(p4a!, closeTo(31.76, 0.1));
    });

    test('Standard Module Voltage 0142 parsing (0x360D -> 13.84V)', () {
      // 0142: ((0x36 * 256) + 0x0D) / 1000 = 13837 / 1000 = 13.837 V
      final v = obd.parseStandardModuleVoltage('41 42 36 0D');
      expect(v, isNotNull);
      expect(v!, closeTo(13.84, 0.01));

      // 紧凑十六进制测试
      expect(obd.parseStandardModuleVoltage('414236AF'), closeTo(13.999, 0.01));
      expect(obd.parseStandardModuleVoltage('NO DATA'), isNull);
    });

    test('Standard Odometer 01A6 parsing (0x000BDF02 -> 77798.6 km)', () {
      // 01A6: 0x000BDF02 = 777986 -> / 10.0 = 77798.6 km
      final odo = obd.parseStandardOdometer('41 A6 00 0B DF 02');
      expect(odo, isNotNull);
      expect(odo!, closeTo(77798.6, 0.1));

      // 多帧换行与行号过滤测试 (0: / 1:)
      final odoMulti = obd.parseStandardOdometer('0: 41A6000B\r\n1: DF02\r\n>');
      expect(odoMulti, isNotNull);
      expect(odoMulti!, closeTo(77798.6, 0.1));
    });

    test('Standard Engine Oil Temp 015C parsing (0x40 -> 24 °C)', () {
      // 015C: 0x40 (64) - 40 = 24.0 °C
      expect(obd.parseStandardTemp('41 5C 40'), equals(24.0));
      expect(obd.parseStandardTemp('415C5A'), equals(50.0));
    });

    test('Standard MAF 0110 parsing (0x0003 -> 0.03 g/s)', () {
      expect(obd.parseStandardMaf('41 10 00 03'), equals(0.03));
      expect(obd.parseStandardMaf('41100320'), equals(8.0));
    });

    test('Standard Barometric Pressure 0133 parsing (0x63 -> 99 kPa)', () {
      expect(obd.parseStandardBaro('41 33 63'), equals(99.0));
      expect(obd.parseStandardBaro('413364'), equals(100.0));
    });

    test('Standard Catalyst Temp 013C parsing (0x163B -> 529.1 °C)', () {
      // 013C: ((0x16 * 256 + 0x3B) / 10) - 40 = (5691 / 10) - 40 = 529.1 °C
      final cat = obd.parseStandardCatTemp('41 3C 16 3B');
      expect(cat, isNotNull);
      expect(cat!, closeTo(529.1, 0.1));
    });
  });

  group('Toyota TNGA THS-II UDS Mode 22 DID Decoders', () {
    final obd = CarObdService();

    test('TNGA 221024 Hybrid Core (SOC 40.39%, Voltage 174.2V, Current -9.8A)', () {
      // 62 10 24:
      // Byte 0: 0x67 (103) -> 103 * 100 / 255 = ~40.39%
      // Bytes 1-2: 0x06CE (1742) -> 174.2 V
      // Bytes 3-4: 0x7C2C (31788) -> (31788 - 32768) * 0.01 = -9.80 A
      obd.parseToyotaTnga221024ForTesting('62 10 24 67 06 CE 7C 2C');
      final tel = obd.telemetryNotifier.value;

      expect(tel.batterySoc, isNotNull);
      expect(tel.batterySoc!, closeTo(40.39, 0.1));
      expect(tel.batteryVoltage, isNotNull);
      expect(tel.batteryVoltage!, closeTo(174.2, 0.1));
      expect(tel.batteryCurrent, isNotNull);
      expect(tel.batteryCurrent!, closeTo(-9.80, 0.01));
      expect(tel.batteryPowerKw, isNotNull);
      expect(tel.batteryPowerKw!, closeTo(-1.707, 0.05));
    });

    test('TNGA 221100 Inverters & Boost Converter (VL 150V, VH 250V, MG1/MG2 Temps)', () {
      // 62 11 00:
      // Bytes 0-1: 0x05DC (1500) -> 150.0 V
      // Bytes 2-3: 0x09C4 (2500) -> 250.0 V
      // Byte 4: 0x50 (80) -> 80 - 40 = 40.0 °C (MG1)
      // Byte 5: 0x52 (82) -> 82 - 40 = 42.0 °C (MG2)
      // Byte 6: 0x55 (85) -> 85 - 40 = 45.0 °C (Transaxle Oil)
      obd.parseToyotaTnga221100ForTesting('62 11 00 05 DC 09 C4 50 52 55');
      final tel = obd.telemetryNotifier.value;

      expect(tel.voltageBeforeBoost, closeTo(150.0, 0.1));
      expect(tel.voltageAfterBoost, closeTo(250.0, 0.1));
      expect(tel.mg1InverterTemp, equals(40.0));
      expect(tel.mg2InverterTemp, equals(42.0));
      expect(tel.transaxleOilTemp, equals(45.0));
    });

    test('TNGA 222884 Battery Cell Extremes and Avg Voltage (Max 3.631V, Min 3.620V, Avg 3.625V, Delta 11mV)', () {
      // 62 28 84:
      // Bytes 0-1: 0x0E2F (3631) -> 3.631 V
      // Bytes 2-3: 0x0E24 (3620) -> 3.620 V
      // Bytes 4-5: 0x0E29 (3625) -> 3.625 V
      obd.parseToyotaTnga222884ForTesting('62 28 84 0E 2F 0E 24 0E 29');
      final tel = obd.telemetryNotifier.value;

      expect(tel.maxCellVoltage, closeTo(3.631, 0.001));
      expect(tel.minCellVoltage, closeTo(3.620, 0.001));
      expect(tel.avgCellVoltage, closeTo(3.625, 0.001));
      expect(tel.cellDeltaVoltage, closeTo(0.011, 0.001));
    });

    test('TNGA 222885 Battery Pack 6-Point Temperatures (26°C - 28°C)', () {
      // 62 28 85: 0x42 (66-40=26), 0x43 (27), 0x44 (28), 0x43 (27), 0x42 (26), 0x43 (27)
      obd.parseToyotaTnga222885ForTesting('62 28 85 42 43 44 43 42 43');
      final tel = obd.telemetryNotifier.value;

      expect(tel.batteryTemperatures.length, equals(6));
      expect(tel.batteryTemperatures, equals([26.0, 27.0, 28.0, 27.0, 26.0, 27.0]));
    });

    test('TNGA 221234 Electric Water Pump (Actual 1700 RPM, Target 1680 RPM, Oil Temp 24°C)', () {
      // 62 12 34: Bytes 0-1: 0x06A4 (1700 rpm), Bytes 2-3: 0x0690 (1680 rpm), Byte 4: 0x40 (24 °C)
      obd.parseToyotaTnga221234ForTesting('62 12 34 06 A4 06 90 40');
      final tel = obd.telemetryNotifier.value;

      expect(tel.electricWaterPumpRpm, equals(1700.0));
      expect(tel.electricWaterPumpTargetRpm, equals(1680.0));
      expect(tel.engineOilTemp, equals(24.0));
    });

    test('TNGA 221102 Dual Motor Status & Torques (MG1 -2500 rpm, MG2 4200 rpm, MG2 Torque +45.5 Nm, Regen Torque -30.0 Nm)', () {
      // 62 11 02:
      // MG1: -2500 -> 0xF63C (65536 - 2500 = 63036 = 0xF63C)
      // MG2: 4200 -> 0x1068 (4200)
      // MG2 Torque: 45.5 Nm * 8 = 364 -> 0x016C
      // Regen Torque: -30.0 Nm * 8 = -240 -> 65536 - 240 = 65296 -> 0xFF10
      obd.parseToyotaTnga221102ForTesting('62 11 02 F6 3C 10 68 01 6C FF 10');
      final tel = obd.telemetryNotifier.value;

      expect(tel.mg1Rpm, equals(-2500.0));
      expect(tel.mg2Rpm, equals(4200.0));
      expect(tel.mg2Torque, closeTo(45.5, 0.1));
      expect(tel.regenBrakingTorque, closeTo(-30.0, 0.1));
    });

    test('TNGA 222006 HV Total Odometer (77827.2 km)', () {
      // 62 20 06: 0x000BE020 (778272) -> 77827.2 km
      obd.parseToyotaTnga222006ForTesting('62 20 06 00 0B E0 20');
      final tel = obd.telemetryNotifier.value;

      expect(tel.totalOdometerKm, closeTo(77827.2, 0.1));
    });

    test('Expanded Standard Mode 01 decoders (STFT, LTFT, Timing, RunTime, Lambda, CatTemp2, RelThrottle, Actuator)', () {
      // 0106 STFT: 0x80 (128) -> 0.0%, 0x8A (138) -> (10 * 100 / 128) = +7.81%
      expect(obd.parseFuelTrim('41 06 80'), closeTo(0.0, 0.1));
      expect(obd.parseFuelTrim('41 06 8A'), closeTo(7.81, 0.1));

      // 0107 LTFT: 0x7A (122) -> (-6 * 100 / 128) = -4.68%
      expect(obd.parseFuelTrim('41 07 7A'), closeTo(-4.68, 0.1));

      // 010E Timing Advance: 0x80 (128) -> 0.0°, 0x94 (148) -> (20 / 2) = +10.0°
      expect(obd.parseTimingAdvance('41 0E 80'), equals(0.0));
      expect(obd.parseTimingAdvance('41 0E 94'), equals(10.0));

      // 011F Run Time: 0x012C (300) -> 300 s
      expect(obd.parseRunTime('41 1F 01 2C'), equals(300));

      // 0134 Lambda: 0x8000 (32768) -> 1.000 λ, 0x7CCD (31949) -> 0.975 λ
      expect(obd.parseLambda('41 34 80 00'), closeTo(1.0, 0.001));
      expect(obd.parseLambda('41 34 7C CD'), closeTo(0.975, 0.001));

      // 013D Cat Temp 2: 0x163B -> 529.1 °C
      expect(obd.parseStandardCatTemp('41 3D 16 3B'), closeTo(529.1, 0.1));

      // 0145 Relative Throttle: 0x33 (51) -> 20.0%
      expect(obd.parsePercent('41 45 33'), closeTo(20.0, 0.1));

      // 014C Commanded Throttle Actuator: 0x80 (128) -> 50.2%
      expect(obd.parsePercent('41 4C 80'), closeTo(50.2, 0.1));
    });
  });

  group('CarObdService Safety & Proprietary Polling Default Isolation Tests', () {
    test('Default configuration strictly disables unverified proprietary & standard auto polling', () {
      final obd = CarObdService();
      // 必须严格默认关闭私有协议轮询，严禁盲发 21C3/21C4 等指令
      expect(obd.enableProprietaryPolling, isFalse);
      expect(obd.enableProprietaryPollingNotifier.value, isFalse);

      // 标准轮询也默认关闭，等待显式确认或 0100 响应
      expect(obd.enableStandardPolling, isFalse);
      expect(obd.enableStandardPollingNotifier.value, isFalse);

      // CAN 总线就绪状态初始为 false
      expect(obd.canBusReady, isFalse);
      expect(obd.canBusReadyNotifier.value, isFalse);

      // 验证切换私有探测开关
      obd.setProprietaryPolling(true);
      expect(obd.enableProprietaryPolling, isTrue);
      expect(obd.enableProprietaryPollingNotifier.value, isTrue);

      obd.setProprietaryPolling(false);
      expect(obd.enableProprietaryPolling, isFalse);
      expect(obd.enableProprietaryPollingNotifier.value, isFalse);

      // 验证断开连接时重置 CAN 状态
      obd.canBusReady = true;
      obd.disconnect();
      expect(obd.canBusReady, isFalse);
      expect(obd.canBusReadyNotifier.value, isFalse);
    });
  });
}
