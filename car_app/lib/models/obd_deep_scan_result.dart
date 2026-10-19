class ObdDiscoveredItem {
  final String category; // e.g. '标准OBD (Mode 01)', '丰田混动 (0x7E2)', '发动机ECM (0x7E0)', '车辆信息 (Mode 09)'
  final String header; // e.g. '7DF', '7E2', '7E0'
  final String command; // e.g. '010D', '21C3', '221024'
  final String name; // e.g. '车速 (Vehicle Speed)', '混动核心遥测 (HV Matrix)'
  final String rawHexResponse; // 原始 HEX 应答
  final String? decodedHint; // 解码预览值 (若已知)
  final int responseTimeMs; // 应答耗时
  final bool isSupported; // 是否有效响应 (非 NO DATA / UNABLE / ERROR)

  const ObdDiscoveredItem({
    required this.category,
    required this.header,
    required this.command,
    required this.name,
    required this.rawHexResponse,
    this.decodedHint,
    required this.responseTimeMs,
    required this.isSupported,
  });

  Map<String, dynamic> toJson() {
    return {
      'category': category,
      'header': header,
      'command': command,
      'name': name,
      'raw_hex': rawHexResponse,
      'decoded_hint': decodedHint,
      'response_time_ms': responseTimeMs,
      'is_supported': isSupported,
    };
  }
}

class ObdDeepScanReport {
  final DateTime startTime;
  final DateTime? endTime;
  final String deviceName;
  final String protocolName;
  final List<String> activeEcus;
  final List<ObdDiscoveredItem> items;
  final int totalTested;
  final int totalSupported;

  const ObdDeepScanReport({
    required this.startTime,
    this.endTime,
    required this.deviceName,
    required this.protocolName,
    this.activeEcus = const [],
    this.items = const [],
    required this.totalTested,
    required this.totalSupported,
  });

  Map<String, dynamic> toJson() {
    return {
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'device_name': deviceName,
      'protocol_name': protocolName,
      'active_ecus': activeEcus,
      'total_tested': totalTested,
      'total_supported': totalSupported,
      'support_rate': totalTested > 0 ? '${(totalSupported / totalTested * 100).toStringAsFixed(1)}%' : '0%',
      'items': items.map((e) => e.toJson()).toList(),
    };
  }

  String toMarkdown() {
    final sb = StringBuffer();
    sb.writeln('# 丰田 Yaris Z 混动 (2022) OBD 全车深度扫描报告');
    sb.writeln();
    sb.writeln('> **扫描时间**：${startTime.toLocal().toString().substring(0, 19)}');
    sb.writeln('> **诊断适配器**：$deviceName');
    sb.writeln('> **通信协议**：$protocolName');
    sb.writeln('> **探测结果**：共测试 **$totalTested** 项，车辆成功开放响应 **$totalSupported** 项（支持率 ${(totalTested > 0 ? totalSupported * 100.0 / totalTested : 0).toStringAsFixed(1)}%）');
    sb.writeln();
    sb.writeln('### 一、 车辆活跃 ECU 节点发现');
    if (activeEcus.isEmpty) {
      sb.writeln('- 未识别到独立 ECU 节点');
    } else {
      for (final ecu in activeEcus) {
        sb.writeln('- `$ecu`');
      }
    }
    sb.writeln();
    sb.writeln('### 二、 车辆成功开放的数据清单 (已验证有效响应)');
    sb.writeln('| 分类 | ECU 寻址 | 指令/PID | 传感器名称 | 原始 HEX 响应 | 采样解析/说明 |');
    sb.writeln('| :--- | :--- | :--- | :--- | :--- | :--- |');

    final supportedItems = items.where((i) => i.isSupported).toList();
    for (final item in supportedItems) {
      final safeHex = item.rawHexResponse.length > 32
          ? '${item.rawHexResponse.substring(0, 32)}...'
          : item.rawHexResponse;
      sb.writeln('| ${item.category} | `0x${item.header}` | `${item.command}` | ${item.name} | `$safeHex` | ${item.decodedHint ?? "原始多字节报文"} |');
    }

    sb.writeln();
    sb.writeln('---');
    sb.writeln('*报告由 MyYaris 车机助手 (Ottocast P3 Pro) 自动化深度探测引擎生成*');
    return sb.toString();
  }
}
