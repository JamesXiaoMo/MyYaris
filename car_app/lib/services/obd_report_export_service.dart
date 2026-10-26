import 'dart:convert';
import 'package:flutter/services.dart';
import '../models/obd_deep_scan_result.dart';

class ObdReportExportResult {
  final String path, integrity;
  final bool complete;
  const ObdReportExportResult(this.path, this.integrity, this.complete);
}

/// Explicit, sensitive-confirmed export only. The native worker copies its actual files.
class ObdReportExportService {
  static const channel = MethodChannel('com.myyaris.my_yaris/obd_reports');
  static Future<ObdReportExportResult> export(
    ObdDeepScanReport report, {
    bool share = false,
  }) async {
    final ready = await report.prepareForExport?.call() ?? report;
    final result = await channel
        .invokeMapMethod<String, dynamic>('export', {
          'json': ready.toJsonText(),
          'markdown': ready.toMarkdown(),
          'share': share,
          'session': ready.transportStorage['session'],
          'storage': ready.transportStorage,
          'expectedJournal': ready.transportEvents
              .map((e) => '${jsonEncode(e)}\n')
              .join(),
        })
        .timeout(const Duration(seconds: 5));
    final path = result?['path'];
    if (path is! String || path.isEmpty) throw StateError('未收到诊断包保存结果');
    return ObdReportExportResult(
      path,
      result?['integrity'] as String? ?? 'unknown',
      result?['complete'] == true,
    );
  }
}
