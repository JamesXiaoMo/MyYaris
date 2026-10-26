import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/models/obd_deep_scan_result.dart';
import 'package:my_yaris/models/elm_obd_response.dart';
import 'package:my_yaris/services/obd_report_export_service.dart';
import 'package:my_yaris/services/obd_transport_journal.dart';
import 'package:my_yaris/services/car_obd_service.dart';
import 'package:my_yaris/ui/obd_deep_scan_dialog.dart';

ObdDeepScanReport report() => ObdDeepScanReport(
  startTime: DateTime.utc(2026, 1, 1),
  deviceName: 'test adapter',
  protocolName: 'test',
  totalTested: 2,
  totalSupported: 1,
  outcome: 'cancelled',
  items: [
    ObdDiscoveredItem(
      category: 'test',
      header: '7DF',
      command: '0902',
      name: 'VIN',
      rawHexResponse: '490201${List.filled(17, '31').join()}\r>',
      responseTimeMs: 11,
      isSupported: true,
      reason: 'matched_response',
      completion: 'prompt',
      frames: const [ObdFrameEvidence('unknown', '490201', 'positive')],
    ),
    const ObdDiscoveredItem(
      category: 'test',
      header: '7E0',
      command: '221234',
      name: 'candidate',
      rawHexResponse: 'SEARCHING...\r7F 22 31\rTIMEOUT\rfull failure tail',
      responseTimeMs: 1400,
      isSupported: false,
      reason: 'timeout',
      completion: 'timeout',
      candidate: true,
    ),
  ],
  trace: const [
    {'phase': 'restore', 'acknowledged': false, 'raw': 'FULL ERROR'},
  ],
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ObdReportExportService.channel, (call) async {
          calls.add(call);
          return call.method == 'export'
              ? {
                  'path': 'private/obd_bundles/test.zip',
                  'complete': true,
                  'integrity': 'complete_within_window',
                }
              : null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ObdReportExportService.channel, null),
  );
  test(
    'JSON and Markdown export preserve full success/failure and sensitivity notice',
    () async {
      final r = report();
      final json = jsonDecode(r.toJsonText());
      expect(json['items'].length, 2);
      expect(json['items'][1]['raw_hex'], r.items[1].rawHexResponse);
      expect(json['items'][0]['raw_hex'], r.items[0].rawHexResponse);
      expect(r.toMarkdown(), contains(r.items[0].rawHexResponse));
      expect(r.toMarkdown(), contains('full failure tail'));
      expect(r.toMarkdown(), contains('FULL ERROR'));
      expect(r.toMarkdown(), contains(ObdDeepScanReport.sensitiveNotice));
      expect(json['matched_response_count'], 1);
      expect(json['parsed_count'], 0);
      await ObdReportExportService.export(r);
      expect(calls.single.arguments['json'], r.toJsonText());
      expect(calls.single.arguments['markdown'], r.toMarkdown());
      expect(calls.single.arguments['share'], isFalse);
    },
  );
  testWidgets(
    'debug dialog export waits for sensitive confirmation and exports both formats',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final service = CarObdService.forTesting((_) async {});
      service.lastDeepScanReportNotifier.value = report();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ObdDeepScanDialog(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('保存完整诊断包'));
      await tester.pumpAndSettle();
      expect(find.text(ObdDeepScanReport.sensitiveNotice), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(find.text('保存完整诊断包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect(calls.single.arguments['share'], isFalse);
      expect(calls.single.arguments['json'], report().toJsonText());
      await tester.tap(find.text('分享完整诊断包'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      expect(calls.last.arguments['share'], isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'small-screen export stays busy until completion and warns on incomplete native logs',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 480));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final pending = Completer<Map<String, dynamic>>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ObdReportExportService.channel, (
            call,
          ) async {
            calls.add(call);
            return pending.future;
          });
      final service = CarObdService.forTesting((_) async {});
      service.lastDeepScanReportNotifier.value = report();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ObdDeepScanDialog(service: service)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存完整诊断包'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在封存日志...'), findsOneWidget);
      final share = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '分享完整诊断包'),
      );
      expect(share.onPressed, isNull);
      pending.complete({
        'path': 'private/test.zip',
        'complete': false,
        'integrity': 'incomplete',
      });
      await tester.pumpAndSettle();
      expect(find.textContaining('日志不完整/受限'), findsOneWidget);
      expect(calls.length, 1);
      expect(tester.takeException(), isNull);
    },
  );
  test('native export errors remain visible failures', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          ObdReportExportService.channel,
          (_) async => throw PlatformException(code: 'EXPORT_FAILED'),
        );
    await expectLater(
      ObdReportExportService.export(report()),
      throwsA(isA<PlatformException>()),
    );
  });
  test(
    'byte journal uses only the private native sink, without export or share',
    () async {
      final journal = ObdTransportJournal();
      journal.beginCapture();
      final event = journal.record('rx_notification', {
        'transaction_id': 9,
        'notification_seq': 1,
        'raw_hex': '00FF0D3E',
        'length': 4,
      });
      await journal.flush();
      final rx = calls.singleWhere(
        (c) =>
            c.method == 'appendTransport' &&
            jsonDecode(c.arguments['event'])['phase'] == 'rx_notification',
      );
      expect(rx.arguments['session'], journal.session);
      expect(jsonDecode(rx.arguments['event']), event);
      expect(rx.arguments.containsKey('share'), isFalse);
      expect(
        journal.storageStatus['persisted_through_event'],
        event!['event_seq'],
      );
      expect(journal.storageStatus['storage_failures'], 0);
      journal.stop();
      await journal.flush();
    },
  );
}
