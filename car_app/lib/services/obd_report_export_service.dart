import 'package:flutter/services.dart';
import '../models/obd_deep_scan_result.dart';

/// User-triggered local export only. No network or backend dependency.
class ObdReportExportService {
  static const channel = MethodChannel('com.myyaris.my_yaris/obd_reports');
  static Future<String> export(
    ObdDeepScanReport report, {
    bool share = false,
  }) async {
    final path = await channel.invokeMethod<String>('export', {
      'json': report.toJsonText(),
      'markdown': report.toMarkdown(),
      'share': share,
    });
    if (path == null || path.isEmpty) throw StateError('未收到本地保存结果');
    return path;
  }
}
