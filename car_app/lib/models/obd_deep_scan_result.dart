import 'dart:convert';
import 'elm_obd_response.dart';

class ObdDiscoveredItem {
  final String category;
  final String header;
  final String command;
  final String name;
  final String rawHexResponse;
  final String? decodedHint;
  final int responseTimeMs;

  /// Compatibility name: a matched response, not proof of vehicle-wide support.
  final bool isSupported;
  final String reason;
  final String completion;
  final DateTime? time;
  final List<ObdFrameEvidence> frames;
  final bool candidate;
  const ObdDiscoveredItem({
    required this.category,
    required this.header,
    required this.command,
    required this.name,
    required this.rawHexResponse,
    this.decodedHint,
    required this.responseTimeMs,
    required this.isSupported,
    this.reason = 'unknown',
    this.completion = 'unknown',
    this.time,
    this.frames = const [],
    this.candidate = false,
  });
  Map<String, dynamic> toJson() => {
    'category': category,
    'request_header': header,
    'command': command,
    'name': name,
    'raw_hex': rawHexResponse,
    'decoded_hint': decodedHint,
    'response_time_ms': responseTimeMs,
    'matched_response': isSupported,
    'reason': reason,
    'completion': completion,
    'time': time?.toIso8601String(),
    'candidate_unverified': candidate,
    'received_ecu_headers': frames.isEmpty
        ? ['unknown']
        : frames.map((f) => f.ecu).toSet().toList(),
    'frames': frames.map((e) => e.toJson()).toList(),
  };
}

class ObdDeepScanReport {
  static const sensitiveNotice =
      '报告可能包含 VIN、车辆标识及原始诊断数据。仅保存在 App 私有目录；复制或分享前请确认接收方，不要提交到公开仓库。';
  final DateTime startTime;
  final DateTime? endTime;
  final String deviceName;
  final String protocolName;
  final List<String> activeEcus;
  final List<ObdDiscoveredItem> items;
  final int totalTested;
  final int totalSupported;
  final String outcome;
  final List<Map<String, dynamic>> trace;
  const ObdDeepScanReport({
    required this.startTime,
    this.endTime,
    required this.deviceName,
    required this.protocolName,
    this.activeEcus = const [],
    this.items = const [],
    required this.totalTested,
    required this.totalSupported,
    this.outcome = 'completed',
    this.trace = const [],
  });
  int get parsedCount =>
      items.where((i) => i.decodedHint != null && !i.candidate).length;
  Map<String, dynamic> toJson() => {
    'schema_version': 2,
    'sensitive_notice': sensitiveNotice,
    'scope':
        'Fixed 57 candidate probes plus explicit ECU discovery 0100; not all ECUs or vehicle capability coverage.',
    'start_time': startTime.toIso8601String(),
    'end_time': endTime?.toIso8601String(),
    'device_name': deviceName,
    'protocol_name': protocolName,
    'active_ecus': activeEcus,
    'outcome': outcome,
    'total_tested': totalTested,
    'matched_response_count': totalSupported,
    'parsed_count': parsedCount,
    'items': items.map((e) => e.toJson()).toList(),
    'trace': trace,
  };
  String toJsonText() => const JsonEncoder.withIndent('  ').convert(toJson());
  String toMarkdown() {
    final b = StringBuffer('# OBD 扫描证据报告\n\n');
    b.writeln('> $sensitiveNotice\n');
    b.writeln(
      '- 时间：${startTime.toIso8601String()} — ${endTime?.toIso8601String() ?? "unknown"}',
    );
    b.writeln('- 适配器：$deviceName；协议：$protocolName；结果：$outcome');
    b.writeln(
      '- 已测 $totalTested 项；匹配响应 $totalSupported 项；标准值解析 $parsedCount 项。',
    );
    b.writeln(
      '- 范围：固定 57 项候选（40 Mode 01、4 Mode 09、13 私有）及显式 0100 节点发现；不是全车支持率或全部 ECU 遍历。',
    );
    b.writeln(
      '- 已识别响应 ECU：${activeEcus.isEmpty ? "未发现（不虚构节点）" : activeEcus.join(", ")}\n',
    );
    for (final i in items) {
      b.writeln(
        '## ${i.command} ${i.name}${i.candidate ? "（候选/地址与解码未验证）" : ""}\n',
      );
      b.writeln(
        '- 请求 header：${i.header}；时间：${i.time?.toIso8601String() ?? "unknown"}；耗时：${i.responseTimeMs} ms',
      );
      b.writeln('- 判定：${i.reason}；完成状态：${i.completion}；匹配响应：${i.isSupported}');
      b.writeln(
        '- 接收 ECU：${i.frames.isEmpty ? "unknown" : i.frames.map((f) => f.ecu).toSet().join(", ")}',
      );
      if (i.decodedHint != null) b.writeln('- 解析：${i.decodedHint}');
      // Indent raw data rather than fencing: arbitrary replies cannot terminate a fence.
      b.writeln('\n原始完整回复：\n');
      for (final line in i.rawHexResponse.split('\n')) {
        b.writeln('    $line');
      }
      b.writeln('\n逐帧判定：\n');
      for (final f in i.frames) {
        b.writeln('    ${jsonEncode(f.toJson())}');
      }
      b.writeln();
    }
    b.writeln('## 事务与恢复证据\n');
    for (final t in trace) {
      b.writeln('    ${jsonEncode(t)}');
    }
    return b.toString();
  }
}
