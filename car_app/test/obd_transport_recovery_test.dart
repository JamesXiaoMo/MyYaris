import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/elm_obd_response.dart';
import 'package:my_yaris/services/car_obd_service.dart';
import 'package:my_yaris/services/obd_transport_journal.dart';

class ByteElm {
  late final CarObdService service = createService();
  CarObdService createService() {
    final service = CarObdService.forTesting(
      write,
      journalSink: (event) async {
        events.add(event);
      },
    );
    service.beginTransportForTesting();
    return service;
  }

  final commands = <String>[];
  final events = <Map<String, dynamic>>[];
  final delivered = <int>[];
  Future<void> Function(String)? intercept;

  Future<void> write(List<int> bytes) async {
    final cmd = ascii.decode(bytes).trim();
    commands.add(cmd);
    if (intercept != null) return intercept!(cmd);
    answer(cmd);
  }

  void receive(List<int> bytes) {
    delivered.addAll(bytes);
    service.receiveBytesForTesting(bytes);
  }

  void text(String text) => receive(latin1.encode(text));
  void answer(String cmd) => text(
    cmd == 'ATDP'
        ? 'CAN\r>'
        : cmd == 'ATDPN'
        ? '6\r>'
        : cmd == '0100'
        ? '7E8064100BE3FA813\r>'
        : cmd == '0104'
        ? '7E80341047F\r>'
        : cmd.startsWith('AT')
        ? 'OK\r>'
        : 'NO DATA\r>',
  );
  Future<void> prime() async {
    for (final cmd in ['ATSH7E0', 'ATH0', 'ATCAF1']) {
      await service.sendRawCommand(cmd);
    }
    await service.flushJournalForTesting();
    commands.clear();
    events.clear();
    delivered.clear();
  }
}

void main() {
  test(
    'first prompt completes reply; trailing bytes are fenced until a NEW prompt',
    () async {
      final elm = ByteElm();
      elm.intercept = (cmd) async =>
          elm.text(cmd == 'ATI' ? 'OK\r>410D01' : '12.5V\r>');
      expect(await elm.service.sendRawCommand('ATI'), 'OK');
      final next = elm.service.sendRawCommand('ATRV');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(elm.commands, ['ATI']);
      elm.text('>');
      expect(await next, '12.5V');
      expect(elm.commands, ['ATI', 'ATRV']);
    },
  );

  test(
    'every two-way byte split including CRLF and standalone prompt is conserved',
    () async {
      const raw = '7E803410D7F\r\n>';
      for (var split = 0; split <= raw.length; split++) {
        final elm = ByteElm();
        elm.intercept = (_) async {
          elm.text(raw.substring(0, split));
          elm.text(raw.substring(split));
        };
        final reply = await elm.service.exchangeForTesting(
          '010D',
          timeout: const Duration(milliseconds: 200),
        );
        expect(reply.raw, raw);
        expect(reply.completion, 'prompt');
        expect(ElmObdParser.classify(reply, '010D').positive, isTrue);
        await elm.service.flushJournalForTesting();
        final rx = elm.events
            .where((e) => e['phase'] == 'rx_notification')
            .toList();
        expect(
          rx.length,
          2,
        ); // Includes an empty notification at either split edge.
        expect(rx.every((e) => e['received_us'] <= e['mono_us']), isTrue);
        expect(
          rx.map((e) => e['raw_hex']).join(),
          ElmObdParser.hex(ascii.encode(raw)),
        );
        expect(rx.fold<int>(0, (n, e) => n + (e['length'] as int)), raw.length);
        expect(reply.transport['first_rx_us'], isNotNull);
        expect(reply.transport['last_rx_us'], isNotNull);
        expect(reply.transport['prompt_us'], isNotNull);
        expect(reply.transport['write_attempted'], isTrue);
        expect(reply.transport['write_completed'], isTrue);
        expect(
          reply.transport['deadline_us'],
          greaterThan(reply.transport['start_us']),
        );
      }
    },
  );

  test(
    'non-ASCII notification bytes survive journal and raw reply without replacement',
    () async {
      final elm = ByteElm();
      elm.intercept = (_) async => elm.receive([0, 0xFF, 0x80, 13, 62]);
      final reply = await elm.service.exchangeForTesting(
        '010D',
        timeout: const Duration(milliseconds: 100),
      );
      expect(latin1.encode(reply.raw), [0, 0xFF, 0x80, 13, 62]);
      expect(ElmObdParser.classify(reply, '010D').positive, isFalse);
      await elm.service.flushJournalForTesting();
      expect(
        elm.events.singleWhere(
          (e) => e['phase'] == 'rx_notification',
        )['raw_hex'],
        '00FF800D3E',
      );
    },
  );

  test(
    'late prompt drains old bytes before the next command; it cannot satisfy that command',
    () async {
      final elm = ByteElm();
      elm.intercept = (cmd) async {
        if (cmd == '010D') {
          elm.text('410D');
          Timer(const Duration(milliseconds: 80), () => elm.text('01\r>'));
        } else {
          elm.text('DIFFERENT\r>');
        }
      };
      final first = await elm.service.exchangeForTesting(
        '010D',
        timeout: const Duration(milliseconds: 40),
      );
      expect(first.completion, 'timeout');
      final next = await elm.service.exchangeForTesting(
        'ATI',
        timeout: const Duration(milliseconds: 200),
      );
      expect(next.completion, 'prompt');
      expect(next.raw, 'DIFFERENT\r>');
      expect(elm.commands, ['010D', 'ATI']);
      await elm.service.flushJournalForTesting();
      final late = elm.events
          .where((e) => e['phase'] == 'rx_notification' && e['late'] == true)
          .single;
      expect(late['transaction_id'], first.transport['transaction_id']);
      expect(
        next.transport['transaction_id'],
        isNot(first.transport['transaction_id']),
      );
    },
  );

  test(
    'continuing fragments cannot extend deadline; unsent gate reports real elapsed time',
    () async {
      final elm = ByteElm();
      Timer? fragments;
      elm.intercept = (_) async {
        elm.text('410D');
        fragments = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => elm.text('00'),
        );
      };
      try {
        final first = await elm.service.exchangeForTesting(
          '010D',
          timeout: const Duration(milliseconds: 60),
        );
        expect(first.completion, 'timeout');
        expect(first.elapsedMs, inInclusiveRange(45, 300));
        final next = await elm.service.exchangeForTesting(
          'ATI',
          timeout: const Duration(milliseconds: 200),
        );
        expect(next.completion, 'unsynchronized_not_sent');
        expect(next.elapsedMs, greaterThanOrEqualTo(480));
        expect(next.transport['write_attempted'], isFalse);
        expect(elm.commands, ['010D']);
      } finally {
        fragments?.cancel();
      }
    },
  );

  test(
    'timed-out native write remains fenced even if an old prompt arrives',
    () async {
      final elm = ByteElm();
      final release = Completer<void>();
      elm.intercept = (_) async {
        elm.text('OK\r>');
        await release.future;
      };
      final first = await elm.service.exchangeForTesting(
        'ATI',
        timeout: const Duration(milliseconds: 40),
      );
      expect(first.completion, 'timeout');
      final blocked = elm.service.exchangeForTesting(
        'ATRV',
        timeout: const Duration(milliseconds: 100),
      );
      elm.text('>');
      final reply = await blocked;
      expect(reply.transport['write_attempted'], isFalse);
      expect(elm.commands, ['ATI']);
      release.complete();
      await Future<void>.delayed(Duration.zero);
    },
  );

  test(
    'scan has one drain decision; all promptless late fragments persist in JSON and Markdown',
    () async {
      final elm = ByteElm();
      await elm.prime();
      Timer? fragments;
      elm.intercept = (cmd) async {
        if (cmd == '0104') {
          elm.text('7E8034104');
          fragments = Timer.periodic(
            const Duration(milliseconds: 40),
            (_) => elm.receive([0xFF, 0x00]),
          );
        } else {
          elm.answer(cmd);
        }
      };
      try {
        final report = (await elm.service.runDeepScan())!;
        expect(report.outcome, 'incomplete_transport');
        expect(report.items.single.completion, 'timeout');
        expect(
          report.items.single.responseTimeMs,
          inInclusiveRange(1380, 1700),
        );
        expect(elm.commands.last, '0104');
        expect(
          report.trace.where((t) => t['phase'] == 'restore_sync').length,
          1,
        );
        expect(
          report.trace.singleWhere(
            (t) => t['phase'] == 'restore_sync',
          )['elapsed_ms'],
          greaterThanOrEqualTo(480),
        );
        expect(
          report.trace.where((t) => t['phase'] == 'late_fragment'),
          isNotEmpty,
        );
        expect(
          report.trace.where((t) => t['phase'] == 'late_reply_drain'),
          isEmpty,
        );
        expect(report.trace.last['polling_suspended'], isTrue);
        final events =
            (jsonDecode(report.toJsonText()) as Map)['transport_events']
                as List;
        final rx = events
            .where((e) => e['phase'] == 'rx_notification')
            .toList();
        expect(
          rx.map((e) => e['raw_hex']).join(),
          ElmObdParser.hex(elm.delivered),
        );
        for (var i = 1; i < rx.length; i++) {
          expect(rx[i]['notification_seq'], rx[i - 1]['notification_seq'] + 1);
          expect(rx[i]['mono_us'], greaterThanOrEqualTo(rx[i - 1]['mono_us']));
        }
        final mdEvents = report
            .toMarkdown()
            .split('## 逐通知与事务传输证据')
            .last
            .split('\n')
            .where((l) => l.startsWith('    {'))
            .map((l) => jsonDecode(l.trim()))
            .toList();
        expect(mdEvents, events);
        expect(report.transportStorage['storage_failures'], 0);
        expect(
          report.transportStorage['persisted_through_event'],
          greaterThanOrEqualTo(events.last['event_seq']),
        );
      } finally {
        fragments?.cancel();
      }
    },
  );

  test(
    'unknown original state is never replaced by a fallback or successful restoration',
    () async {
      final elm = ByteElm();
      final report = (await elm.service.runDeepScan(
        onProgress: (p, s, i) {
          if (i != null) elm.service.cancelDeepScan();
        },
      ))!;
      expect(report.trace.first['header'], 'unknown');
      expect(
        report.trace
            .where((t) => t['completion'] == 'unknown_original_not_restored')
            .length,
        3,
      );
      expect(report.trace.last['restoration_acknowledged'], isFalse);
      expect(elm.service.isPollingSuspended, isTrue);
      expect(elm.commands.last, '0104');
    },
  );

  test(
    'native journal failure stops the sink and preserves an explicit incomplete capture',
    () async {
      var attempts = 0;
      final journal = ObdTransportJournal(
        test: true,
        sink: (_) async {
          if (++attempts == 1) throw StateError('simulated disk failure');
        },
      );
      journal.beginCapture();
      journal.record('rx_notification', {'raw_hex': '00FF', 'length': 2});
      journal.record('prompt');
      await journal.flush();
      expect(attempts, 1);
      expect(journal.storageStatus['storage_failures'], 1);
      expect(journal.storageStatus['persisted_through_event'], 0);
      expect(journal.storageStatus['first_failed_event'], 1);
      expect(journal.storageStatus['stop_reason'], 'storage_failure');
    },
  );

  test(
    'damaged lines cannot invent ECU 030 or a truncated/overlong frame source',
    () {
      for (final raw in [
        '03030000000\r>',
        '7EA216210220102030405060708090A\r>',
        '7EA2\r>',
        '7E803410D\r>',
        '7E8 9 03 41 0D 7F\r>',
      ]) {
        final evidence = ElmObdParser.classify(
          ElmReply(raw, 'prompt'),
          '221022',
        );
        expect(evidence.positive, isFalse);
        expect(
          evidence.frames.every((f) => f.ecu == 'unknown'),
          isTrue,
          reason: raw,
        );
      }
    },
  );

  test(
    'missing, repeated and out-of-order CF cannot become a successful exchange',
    () {
      const ff = '7E8 10 0A 62 10 24 01 02 03\r';
      const cf = '7E8 21 04 05 06 07 00 00 00\r';
      for (final stream in [
        ff,
        '$ff$cf$cf',
        '${ff}7E8 22 04 05 06 07\r',
        '${ff}7E8 21 04\r',
      ]) {
        expect(
          ElmObdParser.classify(
            ElmReply('$stream>', 'prompt'),
            '221024',
          ).positive,
          isFalse,
        );
      }
      final timeout = ElmObdParser.classify(ElmReply(ff, 'timeout'), '221024');
      expect(timeout.frames.single.verdict, 'timeout');
      expect(timeout.frames.single.structureVerdict, 'incomplete_multiframe');
    },
  );
  test(
    'real transport preserves interleaved multi-ECU frames across arbitrary slices',
    () async {
      const ff = '7E8100A621024010203\r';
      const cf = '7E82104050607000000\r';
      const other = '7EA100A621024AABBCC\r7EA21DDEEFF7F000000\r';
      for (final entry in <String, bool>{
        '$ff$other$cf>': true,
        '$ff$other>': false,
        '$ff$other$cf$cf>': false,
        '${ff}7E82204050607000000\r>': false,
      }.entries) {
        final elm = ByteElm();
        elm.intercept = (_) async {
          final bytes = ascii.encode(entry.key);
          for (var i = 0; i < bytes.length; i += 3) {
            elm.receive(bytes.sublist(i, (i + 3).clamp(0, bytes.length)));
          }
        };
        final reply = await elm.service.exchangeForTesting(
          '221024',
          timeout: const Duration(milliseconds: 200),
        );
        expect(reply.raw, entry.key);
        expect(ElmObdParser.classify(reply, '221024').positive, entry.value);
        await elm.service.flushJournalForTesting();
        final rx = elm.events.where((e) => e['phase'] == 'rx_notification');
        expect(
          rx.map((e) => e['raw_hex']).join(),
          ElmObdParser.hex(elm.delivered),
        );
      }
    },
  );
  test('malformed colon input is evidence rather than a parser exception', () {
    final reply = ElmReply('41:0D:7F\r>', 'prompt');
    expect(ElmObdParser.classify(reply, '010D').positive, isFalse);
  });
  test(
    'a prompt arriving after the next request budget cannot trigger a late write',
    () async {
      final elm = ByteElm();
      elm.intercept = (_) async => elm.text('PARTIAL');
      expect(
        (await elm.service.exchangeForTesting(
          '010D',
          timeout: const Duration(milliseconds: 40),
        )).completion,
        'timeout',
      );
      final next = elm.service.exchangeForTesting(
        'ATI',
        timeout: const Duration(milliseconds: 50),
      );
      Timer(const Duration(milliseconds: 100), () => elm.text('\r>'));
      final reply = await next;
      expect(reply.completion, 'deadline_not_sent');
      expect(reply.transport['write_attempted'], isFalse);
      expect(elm.commands, ['010D']);
    },
  );
}
