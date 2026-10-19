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

    test('Standard Percent 0111 / 0104 parsing', () {
      // 0x80 (128) * 100 / 255 = ~50.196%
      final p = obd.parsePercent('41 11 80');
      expect(p, isNotNull);
      expect(p!, closeTo(50.19, 0.1));
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
