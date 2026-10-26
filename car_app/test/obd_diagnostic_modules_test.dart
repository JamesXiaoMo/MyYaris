import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/obd_deep_scan_result.dart';
import 'package:my_yaris/services/car_obd_service.dart';
import 'package:my_yaris/ui/obd_deep_scan_dialog.dart';

class FuelElm {
  late final CarObdService service = CarObdService.forTesting(write);
  final commands = <String>[];
  Future<void> Function(String)? intercept;
  String didReply = '7C8056210220102\r>';
  String pidReply = '7C803612924\r>';
  String levelReply = 'NO DATA\r>';

  Future<void> write(List<int> data) async {
    final command = ascii.decode(data).trim();
    commands.add(command);
    if (intercept != null) return intercept!(command);
    answer(command);
  }

  void answer(String command) => service.receiveForTesting(
    command == 'ATDP'
        ? 'CAN\r>'
        : command == 'ATDPN'
        ? '6\r>'
        : command.startsWith('AT')
        ? 'OK\r>'
        : command == '012F'
        ? levelReply
        : command == '221022'
        ? didReply
        : command == '2129'
        ? pidReply
        : command == '0100'
        ? '7E8064100BE3FA813\r>'
        : 'NO DATA\r>',
  );
  Future<void> prime() async {
    for (final command in ['ATSH7E0', 'ATH0', 'ATCAF1']) {
      await service.sendRawCommand(command);
    }
    commands.clear();
  }

  Future<ObdDeepScanReport> fuel({
    void Function(double, String, ObdDiscoveredItem?)? progress,
  }) async => (await service.runDeepScan(
    module: ObdScanModule.fuel,
    onProgress: progress,
  ))!;
  List<String> get requests =>
      commands.where((c) => !c.startsWith('AT')).toList();
}

void main() {
  test(
    'fuel is a separate manual 3-probe transaction with no VIN/CALID/discovery or assignments',
    () async {
      final elm = FuelElm();
      expect(elm.commands, isEmpty);
      await elm.prime();
      final r = await elm.fuel();
      expect(elm.requests, ['012F', '221022', '2129']);
      for (final cmd in elm.requests) {
        final i = elm.commands.indexOf(cmd);
        expect(elm.commands[i - 1], cmd == '012F' ? 'ATSH7DF' : 'ATSH7C0');
      }
      expect(r.totalTested, 3);
      expect(r.totalSupported, 2);
      expect(r.parsedCount, 0);
      expect(
        r.items.every(
          (i) =>
              i.candidate &&
              i.decodedHint == null &&
              i.candidateExplanation != null,
        ),
        isTrue,
      );
      expect(
        r.items
            .where((i) => i.command != '012F')
            .every((i) => i.expectedResponseEcu == '7C8'),
        isTrue,
      );
      expect(r.trace.last['restoration_acknowledged'], isTrue);
      expect(elm.commands.sublist(elm.commands.length - 3), [
        'ATCAF1',
        'ATSH7E0',
        'ATH0',
      ]);
      expect(elm.service.currentTelemetry.fuelLevelLiters, isNull);
      expect(elm.service.currentTelemetry.fuelLevelPercent, isNull);
      expect(elm.service.enableProprietaryPolling, isFalse);
      expect(elm.service.enableStandardPolling, isFalse);
      final json = jsonDecode(r.toJsonText());
      expect(json['module'], 'fuel');
      expect(json['planned_probe_count'], 3);
      expect(json['explicit_discovery_0100'], isFalse);
      expect(r.toMarkdown(), contains('计划 3 项'));
      expect(r.toMarkdown(), isNot(contains('固定 57 项')));
      expect(
        r.transportEvents
            .where((e) => e['phase'] == 'write_start')
            .every((e) => e['write_mode'] == 'fake'),
        isTrue,
      );
    },
  );

  test(
    'standard fuel percentage remains raw evidence and never becomes production telemetry',
    () async {
      final elm = FuelElm()..levelReply = '7E803412F80\r>';
      await elm.prime();
      final r = await elm.fuel();
      expect(r.items.first.isSupported, isTrue);
      expect(r.items.first.decodedHint, isNull);
      expect(r.parsedCount, 0);
      expect(elm.service.currentTelemetry.fuelLevelLiters, isNull);
      expect(elm.service.currentTelemetry.fuelLevelPercent, isNull);
    },
  );

  final cases = <String, (String, String)>{
    'wrong DID prefix': ('7C8056210230102\r>', 'wrong_service_or_pid'),
    'short DID data': ('7C80462102201\r>', 'unexpected_payload_length'),
    'long DID data': ('7C806621022010203\r>', 'unexpected_payload_length'),
    'wrong source': ('7E8056210220102\r>', 'unexpected_response_ecu'),
    'mixed sources': (
      '7E8056210220102\r7C8056210220304\r>',
      'candidate_contract_mismatch',
    ),
    'unknown source': ('6210220102\r>', 'unexpected_response_ecu'),
    'negative response': ('7C8037F2231\r>', 'negative_response'),
    'no data': ('NO DATA\r>', 'no_data'),
  };
  for (final entry in cases.entries) {
    test(
      'fuel strict match rejects ${entry.key} without blocking a completed next candidate',
      () async {
        final elm = FuelElm()..didReply = entry.value.$1;
        await elm.prime();
        final r = await elm.fuel();
        final item = r.items[1];
        expect(item.isSupported, isFalse);
        expect(item.reason, contains(entry.value.$2));
        expect(elm.requests, ['012F', '221022', '2129']);
        expect(r.items.last.isSupported, isTrue);
        expect(r.trace.last['restoration_acknowledged'], isTrue);
      },
    );
  }

  test(
    '2129 requires exact echo and one data byte, without applying any multiplier',
    () async {
      for (final raw in [
        '7C80461292425\r>',
        '7C803612824\r>',
        '7E803612924\r>',
        '7C8037F2112\r>',
      ]) {
        final elm = FuelElm()..pidReply = raw;
        await elm.prime();
        final r = await elm.fuel();
        expect(r.items.last.isSupported, isFalse);
        expect(r.items.last.decodedHint, isNull);
        expect(elm.service.currentTelemetry.fuelLevelLiters, isNull);
      }
    },
  );

  test(
    'cancellation after one candidate restores known original state, without sending the others',
    () async {
      final elm = FuelElm();
      await elm.prime();
      final r = await elm.fuel(
        progress: (p, s, i) {
          if (i != null) elm.service.cancelDeepScan();
        },
      );
      expect(r.outcome, 'cancelled');
      expect(elm.requests, ['012F']);
      expect(r.trace.last['restoration_acknowledged'], isTrue);
      expect(r.trace.last['polling_suspended'], isFalse);
    },
  );

  test(
    'pending cancellation waits for old prompt and never sends next candidate',
    () async {
      final elm = FuelElm();
      await elm.prime();
      elm.intercept = (cmd) async {
        if (cmd == '012F') {
          elm.service.receiveForTesting('7E803412F');
          scheduleMicrotask(elm.service.cancelDeepScan);
          Timer(
            const Duration(milliseconds: 60),
            () => elm.service.receiveForTesting('80\r>'),
          );
        } else {
          elm.answer(cmd);
        }
      };
      final r = await elm.fuel();
      expect(r.outcome, 'cancelled');
      expect(elm.requests, ['012F']);
      expect(r.trace.last['restoration_acknowledged'], isTrue);
      expect(
        r.transportEvents.where((e) => e['phase'] == 'late_prompt'),
        isNotEmpty,
      );
    },
  );

  test(
    'fuel timeout stops before 2129 and leaves restoration unsent and polling suspended',
    () async {
      final elm = FuelElm();
      await elm.prime();
      elm.intercept = (cmd) async {
        if (cmd == '221022') {
          elm.service.receiveForTesting('7C805621022');
        } else {
          elm.answer(cmd);
        }
      };
      final r = await elm.fuel();
      expect(r.outcome, 'incomplete_transport');
      expect(elm.requests, ['012F', '221022']);
      expect(elm.commands.last, '221022');
      expect(r.trace.last['restoration_acknowledged'], isFalse);
      expect(r.trace.last['polling_suspended'], isTrue);
      expect(r.trace.where((e) => e['phase'] == 'restore_sync').length, 1);
    },
  );

  test(
    'unknown original settings remain unknown and cannot be declared restored',
    () async {
      final elm = FuelElm();
      final r = await elm.fuel();
      expect(r.outcome, 'completed_restore_unconfirmed');
      expect(
        r.trace
            .where((e) => e['completion'] == 'unknown_original_not_restored')
            .length,
        3,
      );
      expect(elm.service.isPollingSuspended, isTrue);
      expect(elm.commands.last, '2129');
    },
  );

  test(
    'failed original Header restore ACK remains a failure and never triggers reset',
    () async {
      final elm = FuelElm();
      await elm.prime();
      elm.intercept = (cmd) async {
        if (cmd == 'ATSH7E0') {
          elm.service.receiveForTesting('?\r>');
        } else {
          elm.answer(cmd);
        }
      };
      final r = await elm.fuel();
      expect(r.outcome, 'completed_restore_unconfirmed');
      expect(r.trace.last['restoration_acknowledged'], isFalse);
      expect(elm.service.isPollingSuspended, isTrue);
      expect(
        elm.commands.any(
          (c) => c == 'ATZ' || c == 'ATD' || c == 'ATWS' || c.isEmpty,
        ),
        isFalse,
      );
    },
  );

  test(
    'connected status alone does not let an unsynchronized fuel transaction send any candidates',
    () async {
      final elm = FuelElm();
      await elm.prime();
      elm.intercept = (cmd) async {
        if (cmd != 'ATI') elm.answer(cmd);
      };
      await elm.service.exchangeForTesting(
        'ATI',
        timeout: const Duration(milliseconds: 40),
      );
      final r = await elm.fuel();
      expect(elm.service.isConnected, isTrue);
      expect(r.totalTested, 0);
      expect(elm.requests, isEmpty);
      expect(elm.commands, ['ATI']);
      expect(elm.service.isPollingSuspended, isTrue);
    },
  );

  test(
    'concurrent modules and manual writes cannot enter a fuel transaction',
    () async {
      final elm = FuelElm();
      await elm.prime();
      final entered = Completer<void>();
      elm.intercept = (cmd) async {
        if (cmd == '012F') {
          entered.complete();
        } else {
          elm.answer(cmd);
        }
      };
      final scan = elm.fuel();
      await entered.future;
      expect(
        await elm.service.runDeepScan(module: ObdScanModule.vehicleInfo),
        isNull,
      );
      expect(
        await elm.service.sendRawCommand('ATSH7E8'),
        contains('BUSY_TRANSACTION'),
      );
      elm.service.cancelDeepScan();
      elm.service.receiveForTesting('NO DATA\r>');
      final r = await scan;
      expect(r.outcome, 'cancelled');
      expect(elm.requests, ['012F']);
    },
  );

  test(
    'explicit metadata module retains four requests, with exact separate report scope',
    () async {
      final elm = FuelElm();
      await elm.prime();
      final r = (await elm.service.runDeepScan(
        module: ObdScanModule.vehicleInfo,
      ))!;
      expect(elm.requests, ['0902', '0904', '0906', '090A']);
      expect(r.totalTested, 4);
      expect(r.module, ObdScanModule.vehicleInfo);
      final json = jsonDecode(r.toJsonText());
      expect(json['planned_probe_count'], 4);
      expect(json['explicit_discovery_0100'], isFalse);
      expect(r.toMarkdown(), contains('计划 4 项'));
    },
  );

  test(
    'metadata failure still stops; decoupling never means ignoring missing prompt',
    () async {
      final elm = FuelElm();
      await elm.prime();
      elm.intercept = (cmd) async {
        if (cmd == '0904') {
          elm.service.receiveForTesting('7E81023');
        } else {
          elm.answer(cmd);
        }
      };
      final r = (await elm.service.runDeepScan(
        module: ObdScanModule.vehicleInfo,
      ))!;
      expect(r.outcome, 'incomplete_transport');
      expect(elm.requests, ['0902', '0904']);
      expect(r.trace.last['polling_suspended'], isTrue);
    },
  );

  testWidgets(
    'fuel button requires explicit confirmation and never runs automatically',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final elm = FuelElm();
      await tester.runAsync(() => elm.prime());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ObdDeepScanDialog(service: elm.service)),
        ),
      );
      await tester.pumpAndSettle();
      expect(elm.commands, isEmpty);
      await tester.tap(find.byKey(const ValueKey('obd-fuel-test')));
      await tester.pumpAndSettle();
      expect(find.textContaining('确认油量专项测试'), findsOneWidget);
      expect(elm.commands, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(elm.commands, isEmpty);
      await tester.tap(find.byKey(const ValueKey('obd-fuel-test')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('车辆已停稳，开始'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 120 && elm.service.isDeepScanning; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      await tester.pumpAndSettle();
      expect(elm.requests, ['012F', '221022', '2129']);
      expect(
        elm.service.lastDeepScanReportNotifier.value!.module,
        ObdScanModule.fuel,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
