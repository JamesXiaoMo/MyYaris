import 'dart:convert';
import 'elm_obd_response.dart';

enum ObdScanModule { basic, fuel, vehicleInfo }

extension ObdScanModuleScope on ObdScanModule {
  String get label => switch (this) {
    ObdScanModule.basic => '基础候选扫描',
    ObdScanModule.fuel => '油量专项测试（候选/未验证）',
    ObdScanModule.vehicleInfo => '车辆标识测试（单独）',
  };
  int get plannedCount => switch (this) {
    ObdScanModule.basic => 53,
    ObdScanModule.fuel => 3,
    ObdScanModule.vehicleInfo => 4,
  };
  bool get discoversEcus => this == ObdScanModule.basic;
  String get scope => switch (this) {
    ObdScanModule.basic =>
      '53 fixed candidates (40 Mode 01 + 13 private) plus explicit 0100 discovery; Mode 09 excluded; not vehicle-wide coverage.',
    ObdScanModule.fuel =>
      '3 manual unverified fuel candidates: 7DF/012F, 7C0/221022, 7C0/2129; no VIN/CALID or discovery; no litre conversion or polling.',
    ObdScanModule.vehicleInfo =>
      '4 explicit Mode 09 broadcast metadata requests: 0902, 0904, 0906, 090A; may contain identifiers; independent of basic/fuel tests.',
  };
  String get scopeDescription => switch (this) {
    ObdScanModule.basic =>
      '53 项基础候选（40 Mode 01、13 私有）及显式 0100 发现；不含 Mode 09，不代表全车能力。',
    ObdScanModule.fuel =>
      '3 项手动油量候选：7DF/012F、7C0/221022、7C0/2129；不读取 VIN/CALID，不换算升数或启动轮询。',
    ObdScanModule.vehicleInfo =>
      '4 项独立 Mode 09 广播：0902、0904、0906、090A；含车辆标识，多源长回复可能失步。',
  };
}

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
  final Map<String, dynamic> transport;
  final String? candidateExplanation;
  final String? expectedResponseEcu;
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
    this.transport = const {},
    this.candidateExplanation,
    this.expectedResponseEcu,
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
    'transport': transport,
    'candidate_explanation': candidateExplanation,
    'expected_response_ecu': expectedResponseEcu,
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
  final List<Map<String, dynamic>> transportEvents;
  final Map<String, dynamic> transportStorage;
  final ObdScanModule module;
  final Future<ObdDeepScanReport> Function()? prepareForExport;
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
    this.transportEvents = const [],
    this.transportStorage = const {},
    this.module = ObdScanModule.basic,
    this.prepareForExport,
  });
  ObdDeepScanReport withTransport(
    List<Map<String, dynamic>> events,
    Map<String, dynamic> storage,
  ) => ObdDeepScanReport(
    startTime: startTime,
    endTime: endTime,
    deviceName: deviceName,
    protocolName: protocolName,
    activeEcus: activeEcus,
    items: items,
    totalTested: totalTested,
    totalSupported: totalSupported,
    outcome: outcome,
    trace: trace,
    module: module,
    transportEvents: events,
    transportStorage: storage,
  );

  int get parsedCount =>
      items.where((i) => i.decodedHint != null && !i.candidate).length;
  Map<String, dynamic> toJson() => {
    'schema_version': 5,
    'module': module.name,
    'planned_probe_count': module.plannedCount,
    'explicit_discovery_0100': module.discoversEcus,
    'sensitive_notice': sensitiveNotice,
    'scope': module.scope,
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
    'transport_events': transportEvents,
    'transport_storage': transportStorage,
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
      '- 模块：${module.label}；计划 ${module.plannedCount} 项。\n- 范围：${module.scopeDescription}',
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
      if (i.candidateExplanation != null) {
        b.writeln('- 候选解释：${i.candidateExplanation}');
      }
      if (i.expectedResponseEcu != null) {
        b.writeln('- 预期来源：${i.expectedResponseEcu}');
      }
      // Indent raw data rather than fencing: arbitrary replies cannot terminate a fence.
      b.writeln('\n原始完整回复：\n');
      for (final line in i.rawHexResponse.split('\n')) {
        b.writeln('    $line');
      }
      b.writeln('\n无损原文（JSON 字符串，保留 CR/LF）：\n');
      b.writeln('    ${jsonEncode(i.rawHexResponse)}');
      b.writeln('\n收发元数据：\n');
      b.writeln('    ${jsonEncode(i.transport)}');
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
    b.writeln('\n## 私有传输日志存储状态\n');
    b.writeln('    ${jsonEncode(transportStorage)}');
    b.writeln('\n## 逐通知与事务传输证据（与 JSON transport_events 一致）\n');
    for (final event in transportEvents) {
      b.writeln('    ${jsonEncode(event)}');
    }
    return b.toString();
  }
}
