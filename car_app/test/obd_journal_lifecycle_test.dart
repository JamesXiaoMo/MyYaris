import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/obd_transport_journal.dart';
import 'package:my_yaris/services/car_obd_service.dart';
import 'package:my_yaris/services/obd_report_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'no persistent/background journal outside an explicit test session',
    () async {
      final writes = <Map<String, dynamic>>[];
      final journal = ObdTransportJournal(
        test: true,
        sink: (e) async {
          writes.add(e);
        },
      );
      expect(
        journal.record('rx_notification', {'raw_hex': '00', 'length': 1}),
        isNull,
      );
      await journal.flush();
      expect(writes, isEmpty);
      final capture = journal.beginCapture();
      final first = journal.record('rx_notification', {
        'raw_hex': '00FF',
        'length': 2,
      });
      final core = journal.endCapture(capture);
      final all = await journal.sealForExport(capture);
      expect(first!['session_id'], capture.session);
      expect(core.first['journal_schema'], ObdTransportJournal.schema);
      expect(
        core.first['observation_layer'],
        'application_callbacks_not_HCI_or_CAN_capture',
      );
      expect(all.last['phase'], 'session_stop');
      final count = writes.length;
      expect(
        journal.record('rx_notification', {'raw_hex': '11', 'length': 1}),
        isNull,
      );
      await journal.flush();
      expect(writes.length, count);
      expect(journal.statusFor(capture)['flush_complete'], isTrue);
    },
  );

  test(
    'passive late window exports late bytes and has explicit capture/session cutoffs',
    () async {
      final journal = ObdTransportJournal(
        test: true,
        tailWindow: const Duration(milliseconds: 40),
      );
      final c = journal.beginCapture();
      journal.record('rx_notification', {
        'transaction_id': 3,
        'raw_hex': '0011',
        'length': 2,
      });
      final core = journal.endCapture(c);
      Timer(
        const Duration(milliseconds: 10),
        () => journal.record('rx_notification', {
          'transaction_id': 3,
          'raw_hex': 'FF',
          'length': 1,
          'late': true,
        }),
      );
      final full = await journal.sealForExport(c);
      expect(full.length, greaterThan(core.length));
      final rx = full.where((e) => e['phase'] == 'rx_notification').toList();
      expect(rx.map((e) => e['raw_hex']).join(), '0011FF');
      expect(rx.last['session_rx_bytes'], 3);
      final status = journal.statusFor(c);
      expect(status['capture_end_event'], core.last['event_seq']);
      expect(status['queued_through_event'], full.last['event_seq']);
      expect(status['persisted_through_event'], full.last['event_seq']);
      expect(status['native_closed_ack'], isTrue);
      expect(status['stop_reason'], 'passive_tail_elapsed');
    },
  );

  test(
    'new sessions cannot mutate the old report journal or reuse transaction context',
    () async {
      final journal = ObdTransportJournal(test: true);
      final a = journal.beginCapture();
      journal.record('first', {'transaction_id': 11});
      journal.endCapture(a);
      final b = journal.beginCapture();
      journal.record('second', {'transaction_id': 12});
      journal.endCapture(b);
      final first = await journal.sealForExport(a);
      final second = await journal.sealForExport(b);
      expect(a.session, isNot(b.session));
      expect(first.every((e) => e['session_id'] == a.session), isTrue);
      expect(second.every((e) => e['session_id'] == b.session), isTrue);
      expect(first.any((e) => e['phase'] == 'second'), isFalse);
    },
  );

  test(
    'capacity stop is explicit and never pretends discarded events were persisted',
    () async {
      final journal = ObdTransportJournal(test: true, maxEvents: 3);
      final c = journal.beginCapture();
      journal.record('one');
      journal.record('two');
      expect(
        journal.record('rx_notification', {'raw_hex': '0011', 'length': 2}),
        isNull,
      );
      expect(journal.isRecording, isFalse);
      final full = await journal.sealForExport(c);
      expect(full.last['first_omitted_phase'], 'rx_notification');
      expect(journal.statusFor(c)['truncated'], isTrue);
      expect(journal.statusFor(c)['stop_reason'], 'capacity_limit');
      expect(journal.record('later'), isNull);
    },
  );

  test(
    'queue/sink failure stops further native writes and reports the true durable prefix',
    () async {
      var attempts = 0;
      final journal = ObdTransportJournal(
        test: true,
        sinkTimeout: const Duration(milliseconds: 20),
        sink: (e) async {
          attempts++;
          throw PlatformException(code: 'DISK_FULL');
        },
      );
      final c = journal.beginCapture();
      journal.record('rx_notification', {'raw_hex': 'FF', 'length': 1});
      journal.record('another');
      await journal.flush(c);
      final all = await journal.sealForExport(c);
      expect(attempts, 1);
      expect(all, isNotEmpty);
      final status = journal.statusFor(c);
      expect(status['first_failed_event'], 1);
      expect(status['persisted_through_event'], 0);
      expect(status['pending_bytes'], 0);
      expect(status['error_code'], 'DISK_FULL');
      expect(status['flush_complete'], isFalse);
      expect(status['stop_reason'], 'storage_failure');
    },
  );

  test(
    'a hung sink and full pending queue have bounded memory and a truthful failed flush',
    () async {
      final never = Completer<void>();
      var attempts = 0;
      final journal = ObdTransportJournal(
        test: true,
        maxPendingBytes: 800,
        sinkTimeout: const Duration(milliseconds: 20),
        sink: (e) {
          attempts++;
          return never.future;
        },
      );
      final c = journal.beginCapture();
      for (var n = 0; n < 50; n++) {
        journal.record('rx_notification', {'raw_hex': 'AA' * 64, 'length': 64});
      }
      expect(journal.isRecording, isFalse);
      await journal.flush(c);
      expect(attempts, 1);
      expect(journal.statusFor(c)['truncated'], isTrue);
      expect(journal.statusFor(c)['retained_event_bytes'], lessThan(4096));
      expect(journal.statusFor(c)['flush_complete'], isFalse);
      never.complete();
    },
  );

  test(
    'session deadline stops passive logging even if data never becomes quiet',
    () async {
      final journal = ObdTransportJournal(
        test: true,
        sessionLimit: const Duration(milliseconds: 40),
      );
      final c = journal.beginCapture();
      final timer = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => journal.record('noise'),
      );
      final events = await journal.sealForExport(c);
      timer.cancel();
      expect(events.last['reason'], 'session_time_limit');
      expect(journal.statusFor(c)['truncated'], isTrue);
      expect(journal.isRecording, isFalse);
    },
  );

  test(
    'report save waits for the late window, flush and close before native export',
    () async {
      final native = <MethodCall>[];
      final journalEvents = <Map<String, dynamic>>[];
      final journal = ObdTransportJournal(
        test: true,
        tailWindow: const Duration(milliseconds: 40),
        sink: (e) async {
          journalEvents.add(e);
        },
      );
      late CarObdService service;
      service = CarObdService.forTesting((bytes) async {
        final cmd = ascii.decode(bytes).trim();
        service.receiveForTesting(
          cmd == 'ATDP'
              ? 'CAN\r>'
              : cmd == 'ATDPN'
              ? '6\r>'
              : cmd.startsWith('AT')
              ? 'OK\r>'
              : 'NO DATA\r>',
        );
      }, transportJournal: journal);
      for (final cmd in ['ATSH7DF', 'ATH0', 'ATCAF1']) {
        await service.sendRawCommand(cmd);
      }
      final report = (await service.runDeepScan(
        onProgress: (p, s, i) {
          if (i != null) service.cancelDeepScan();
        },
      ))!;
      expect(report.transportStorage['recording'], isTrue);
      Timer(
        const Duration(milliseconds: 10),
        () => service.receiveBytesForTesting([0xFF, 0]),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ObdReportExportService.channel, (
            call,
          ) async {
            native.add(call);
            return {
              'path': 'private/test.zip',
              'complete': true,
              'integrity': 'complete_within_window',
            };
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(ObdReportExportService.channel, null),
      );
      final result = await ObdReportExportService.export(report);
      expect(result.complete, isTrue);
      expect(native.single.method, 'export');
      final args = native.single.arguments as Map;
      final ready = jsonDecode(args['json']);
      final events = ready['transport_events'] as List;
      expect(events.last['phase'], 'session_stop');
      expect(ready['transport_storage']['flush_complete'], isTrue);
      expect(
        events.where((e) => e['phase'] == 'rx_notification').last['raw_hex'],
        'FF00',
      );
      expect(events.last['session_id'], args['session']);
      expect(
        args['expectedJournal'],
        events.map((e) => '${jsonEncode(e)}\n').join(),
      );
      final md = (args['markdown'] as String).split('## 逐通知与事务传输证据').last;
      final mdEvents = md
          .split('\n')
          .where((l) => l.startsWith('    {'))
          .map((l) => jsonDecode(l.trim()))
          .toList();
      expect(mdEvents, events);
      expect(journalEvents, events);
    },
  );
}
