import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/car_obd_service.dart';

class FakeElm {
  late final CarObdService service = CarObdService.forTesting(write);
  final commands = <String>[];
  String protocol = '6';
  Future<void> Function(String)? intercept;
  Future<void> write(List<int> bytes) async {
    final cmd = ascii.decode(bytes).trim();
    commands.add(cmd);
    if (intercept != null) return intercept!(cmd);
    answer(cmd);
  }

  void answer(String cmd) => service.receiveForTesting(
    cmd == 'ATDP'
        ? 'ISO 15765-4 CAN\r>'
        : cmd == 'ATDPN'
        ? '$protocol\r>'
        : cmd == 'ATRV'
        ? '12.5V\r>'
        : cmd == '0100'
        ? '7E8 06 41 00 BE 3F A8 13\r>'
        : cmd == '0104'
        ? '7E8 03 41 04 7F\r>'
        : cmd == '010F'
        ? '7E8 03 41 0F 50\r>'
        : cmd.startsWith('AT')
        ? 'OK\r>'
        : 'NO DATA\r>',
  );
}

void main() {
  test(
    'real scan retains 57 probes, failures, full raw, headers and standard decode',
    () async {
      final elm = FakeElm();
      final r = (await elm.service.runDeepScan())!;
      expect(r.totalTested, 57);
      expect(r.items.where((i) => i.candidate).length, 13);
      expect(r.totalSupported, 2);
      expect(r.parsedCount, 2);
      expect(r.activeEcus, ['7E8']);
      expect(r.items.first.decodedHint, contains('49.8%'));
      expect(
        r.items.firstWhere((i) => i.command == '010F').decodedHint,
        '40.0 °C',
      );
      expect(
        r.items
            .where((i) => !i.isSupported)
            .every((i) => i.rawHexResponse == 'NO DATA\r>'),
        isTrue,
      );
      var cursor = 5;
      for (final i in r.items) {
        final index = elm.commands.indexOf(i.command, cursor);
        cursor = index + 1;
        expect(elm.commands[index - 1], 'ATSH${i.header}');
      }
      final json = jsonDecode(r.toJsonText()) as Map;
      expect(json['items'].length, 57);
      expect(json.containsKey('support_rate'), isFalse);
      expect(r.toMarkdown(), contains('NO DATA\r>'));
      expect(r.trace.last['restoration_acknowledged'], isTrue);
      expect(elm.commands.sublist(elm.commands.length - 2), [
        'ATSH7DF',
        'ATH0',
      ]);
    },
  );
  test(
    'scan drains whole in-flight poll and rejects manual commands',
    () async {
      final elm = FakeElm();
      final blocked = Completer<void>();
      final entered = Completer<void>();
      elm.service.canBusReady = true;
      elm.service.setStandardPolling(true);
      elm.intercept = (cmd) async {
        if (cmd == 'ATRV') {
          entered.complete();
          await blocked.future;
        }
        elm.answer(cmd);
      };
      final poll = elm.service.pollCycleForTesting();
      await entered.future;
      final scan = elm.service.runDeepScan();
      expect(
        await elm.service.sendRawCommand('ATSH123'),
        contains('BUSY_TRANSACTION'),
      );
      expect(await elm.service.runDeepScan(), isNull);
      await elm.service.pollCycleForTesting();
      expect(elm.commands, ['ATRV']);
      blocked.complete();
      await poll;
      await scan;
      expect(elm.commands.take(5), ['ATRV', '010D', '010C', '0105', 'ATDP']);
      expect(elm.commands, isNot(contains('ATSH123')));
    },
  );
  test(
    'manual exchange before scan drains; later manual writes rejected',
    () async {
      final elm = FakeElm();
      final entered = Completer<void>();
      final release = Completer<void>();
      elm.intercept = (cmd) async {
        if (cmd == 'ATI') {
          entered.complete();
          await release.future;
        }
        elm.answer(cmd);
      };
      final manual = elm.service.sendRawCommand('ATI');
      await entered.future;
      final scan = elm.service.runDeepScan();
      expect(
        await elm.service.sendRawCommand('ATH0'),
        contains('BUSY_TRANSACTION'),
      );
      release.complete();
      await manual;
      await scan;
      expect(elm.commands.take(2), ['ATI', 'ATDP']);
    },
  );
  test(
    'failed header never sends PID to inherited target; trace keeps raw error',
    () async {
      final elm = FakeElm();
      var count = 0;
      elm.intercept = (cmd) async {
        if (cmd == 'ATSH7DF' && ++count == 2) {
          elm.service.receiveForTesting('?\r>');
        } else {
          elm.answer(cmd);
        }
      };
      final r = (await elm.service.runDeepScan())!;
      expect(elm.commands, isNot(contains('0104')));
      expect(r.items.first.completion, 'not_sent_header_failed');
      expect(r.items.first.isSupported, isFalse);
      expect(r.toJsonText(), contains('?\\r>'));
    },
  );
  test('ECU discovery never infers header from payload', () async {
    final elm = FakeElm();
    elm.intercept = (cmd) async {
      if (cmd == '0100') {
        elm.service.receiveForTesting('41007E87EA00\r>');
      } else if (!cmd.startsWith('AT')) {
        elm.service.receiveForTesting('NO DATA\r>');
      } else {
        elm.answer(cmd);
      }
    };
    expect((await elm.service.runDeepScan())!.activeEcus, isEmpty);
  });
  test('cancel after completed probe restores actual prior settings', () async {
    final elm = FakeElm();
    await elm.service.sendRawCommand('ATSH7E0');
    await elm.service.sendRawCommand('ATH1');
    final r = (await elm.service.runDeepScan(
      onProgress: (p, s, i) {
        if (i != null) elm.service.cancelDeepScan();
      },
    ))!;
    expect(r.outcome, 'cancelled');
    expect(r.items.length, 1);
    expect(elm.commands.sublist(elm.commands.length - 2), ['ATSH7E0', 'ATH1']);
    expect(r.trace.last['restoration_acknowledged'], isTrue);
  });
  test(
    'pending cancellation is bounded; late prompt drains before restore',
    () async {
      final elm = FakeElm();
      elm.intercept = (cmd) async {
        if (cmd == '0104') {
          elm.service.receiveForTesting('7E8 03 41 04');
          scheduleMicrotask(elm.service.cancelDeepScan);
          Timer(
            const Duration(milliseconds: 20),
            () => elm.service.receiveForTesting(' 7F\r>'),
          );
        } else {
          elm.answer(cmd);
        }
      };
      final r = (await elm.service.runDeepScan())!;
      expect(r.outcome, 'cancelled');
      expect(r.items.single.completion, 'cancelled');
      expect(r.items.single.isSupported, isFalse);
      expect(r.trace.last['restoration_acknowledged'], isTrue);
    },
  );
  test(
    'timeout fragment retained; no next PID; failed restore suspends polling',
    () async {
      final elm = FakeElm();
      elm.intercept = (cmd) async {
        if (cmd == '0104') {
          elm.service.receiveForTesting('7E8 03 41 04 7F');
        } else {
          elm.answer(cmd);
        }
      };
      final r = (await elm.service.runDeepScan())!;
      expect(r.outcome, 'incomplete_transport');
      expect(r.items.single.completion, 'timeout');
      expect(r.items.single.isSupported, isFalse);
      expect(r.toMarkdown(), contains('7E8 03 41 04 7F'));
      expect(r.trace.last['restoration_acknowledged'], isFalse);
      expect(r.trace.last['polling_suspended'], isTrue);
      expect(elm.commands.last, '0104');
      final before = elm.commands.length;
      await elm.service.pollCycleForTesting();
      expect(elm.commands.length, before);
    },
  );
  test(
    'disconnect preserves fragment; never claims restoration sent',
    () async {
      final elm = FakeElm();
      elm.intercept = (cmd) async {
        if (cmd == '0104') {
          elm.service.receiveForTesting('7E8 03');
          elm.service.disconnectForTesting();
        } else {
          elm.answer(cmd);
        }
      };
      final r = (await elm.service.runDeepScan())!;
      expect(r.outcome, 'disconnected');
      expect(r.items.single.completion, 'disconnected');
      expect(r.items.single.rawHexResponse, '7E8 03');
      expect(
        r.trace.where((t) => t['completion'] == 'not_sent_disconnected').length,
        3,
      );
      expect(r.trace.last['restoration_acknowledged'], isFalse);
    },
  );
  test(
    'protocol mismatch preserves error report and releases scan flag',
    () async {
      final elm = FakeElm()..protocol = '7';
      final r = (await elm.service.runDeepScan())!;
      expect(r.outcome, 'error');
      expect(r.totalTested, 0);
      expect(r.trace.toString(), contains('scan_requires_CAN_11bit'));
      expect(elm.service.isDeepScanning, isFalse);
      expect(elm.commands, ['ATDP', 'ATDPN']);
    },
  );
  test('manual CAF0 and echoed ATDPN restore original formatting', () async {
    final elm = FakeElm();
    await elm.service.sendRawCommand('ATCAF0');
    elm.intercept = (cmd) async {
      if (cmd == 'ATDPN') {
        elm.service.receiveForTesting('AT DPN\rA6\r>');
      } else {
        elm.answer(cmd);
      }
    };
    final r = (await elm.service.runDeepScan(
      onProgress: (p, s, i) {
        if (i != null) elm.service.cancelDeepScan();
      },
    ))!;
    expect(r.items.length, 1);
    expect(elm.commands, contains('ATCAF1'));
    expect(elm.commands.sublist(elm.commands.length - 3), [
      'ATCAF0',
      'ATSH7DF',
      'ATH0',
    ]);
    expect(r.trace.last['restoration_acknowledged'], isTrue);
  });
  test('failed restore ACK is explicit and suspends polling', () async {
    final elm = FakeElm();
    elm.intercept = (cmd) async {
      if (cmd == 'ATH0') {
        elm.service.receiveForTesting('?\r>');
      } else {
        elm.answer(cmd);
      }
    };
    final r = (await elm.service.runDeepScan(
      onProgress: (p, s, i) {
        if (i != null) elm.service.cancelDeepScan();
      },
    ))!;
    expect(r.trace.last['restoration_acknowledged'], isFalse);
    expect(r.trace.last['polling_suspended'], isTrue);
    expect(r.toJsonText(), contains('?\\r>'));
  });
  test(
    'cancel while waiting never interrupts a prior manual exchange',
    () async {
      final elm = FakeElm();
      final entered = Completer<void>();
      final release = Completer<void>();
      elm.intercept = (cmd) async {
        if (cmd == 'ATI') {
          entered.complete();
          await release.future;
        }
        elm.answer(cmd);
      };
      final manual = elm.service.sendRawCommand('ATI');
      await entered.future;
      final scan = elm.service.runDeepScan();
      elm.service.cancelDeepScan();
      release.complete();
      expect(await manual, 'OK');
      final r = (await scan)!;
      expect(r.outcome, 'cancelled');
      expect(r.totalTested, 0);
      expect(elm.commands, ['ATI']);
    },
  );
  test(
    'ambiguous write failure never retries or sends diagnostic followup',
    () async {
      final elm = FakeElm();
      elm.intercept = (cmd) async {
        if (cmd == '0104') throw StateError('fake BLE write failed');
        elm.answer(cmd);
      };
      final r = (await elm.service.runDeepScan())!;
      expect(r.items.single.completion, contains('write_error'));
      expect(elm.commands.where((c) => c == '0104').length, 1);
      expect(elm.commands.last, '0104');
      expect(r.trace.last['restoration_acknowledged'], isFalse);
    },
  );
  test(
    'unacknowledged manual setting invalidates the old adapter snapshot',
    () async {
      final elm = FakeElm();
      await elm.service.sendRawCommand('ATSH7E0');
      elm.intercept = (cmd) async {
        if (cmd == 'ATSH7E2') {
          elm.service.receiveForTesting('?\r>');
        } else {
          elm.answer(cmd);
        }
      };
      await elm.service.sendRawCommand('ATSH7E2');
      final r = (await elm.service.runDeepScan(
        onProgress: (p, s, i) {
          if (i != null) elm.service.cancelDeepScan();
        },
      ))!;
      expect(r.trace.first['header'], 'unknown');
      expect(elm.commands.sublist(elm.commands.length - 2), [
        'ATSH7DF',
        'ATH0',
      ]);
    },
  );
  test(
    'repeated cancellation cannot interrupt finally restoration ACK',
    () async {
      final elm = FakeElm();
      var formattingCount = 0;
      elm.intercept = (cmd) async {
        if (cmd == 'ATCAF1' && ++formattingCount == 2) {
          scheduleMicrotask(elm.service.cancelDeepScan);
          Timer(const Duration(milliseconds: 20), () => elm.answer(cmd));
        } else {
          elm.answer(cmd);
        }
      };
      final r = (await elm.service.runDeepScan(
        onProgress: (p, s, i) {
          if (i != null) elm.service.cancelDeepScan();
        },
      ))!;
      expect(r.outcome, 'cancelled');
      expect(r.trace.last['restoration_acknowledged'], isTrue);
    },
  );
}
