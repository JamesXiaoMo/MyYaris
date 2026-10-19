import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/obd_deep_scan_result.dart';
import '../services/car_obd_service.dart';

class ObdDeepScanDialog extends StatefulWidget {
  const ObdDeepScanDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const ObdDeepScanDialog(),
    );
  }

  @override
  State<ObdDeepScanDialog> createState() => _ObdDeepScanDialogState();
}

class _ObdDeepScanDialogState extends State<ObdDeepScanDialog> {
  final CarObdService _obd = CarObdService();
  final ScrollController _listScrollController = ScrollController();

  double _progress = 0.0;
  String _statusMessage = '就绪：点击下方【开始深度扫描】探测全车开放数据';
  final List<ObdDiscoveredItem> _discoveredItems = [];
  List<String> _activeEcus = [];
  ObdDeepScanReport? _report;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    final existingReport = _obd.lastDeepScanReportNotifier.value;
    if (existingReport != null) {
      _report = existingReport;
      _discoveredItems.addAll(existingReport.items);
      _activeEcus = existingReport.activeEcus;
      _progress = 1.0;
      _statusMessage =
          '上次扫描结果：共测试 ${existingReport.totalTested} 项，车辆开放 ${existingReport.totalSupported} 项';
    }
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (!_obd.isConnected) {
      setState(() {
        _statusMessage = '⚠️ 请先在主界面点击【扫描 OBD】连接 Veepeak 适配器，再执行全车扫描';
      });
      return;
    }

    setState(() {
      _isScanning = true;
      _progress = 0.02;
      _statusMessage = '正在准备全车诊断探针...';
      _discoveredItems.clear();
      _activeEcus.clear();
      _report = null;
    });

    final report = await _obd.runDeepScan(
      onProgress: (progress, status, newItem) {
        if (!mounted) return;
        setState(() {
          _progress = progress;
          _statusMessage = status;
          if (newItem != null) {
            _discoveredItems.insert(0, newItem);
          }
        });
      },
    );

    if (mounted) {
      setState(() {
        _isScanning = false;
        _report = report;
        if (report != null) {
          _activeEcus = report.activeEcus;
          _progress = 1.0;
          _statusMessage =
              '扫描完毕！共测试 ${report.totalTested} 项，车辆成功开放 ${report.totalSupported} 项';
        } else {
          _statusMessage = '扫描已中止或未完成';
        }
      });
    }
  }

  void _cancelScan() {
    _obd.cancelDeepScan();
    setState(() {
      _statusMessage = '正在中止扫描并复位总线报头...';
    });
  }

  void _copyMarkdownReport() {
    if (_report == null) return;
    final md = _report!.toMarkdown();
    Clipboard.setData(ClipboardData(text: md));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('📋 扫描报告已成功复制为 Markdown 格式！可直接粘贴至文档或聊天窗口'),
        backgroundColor: Colors.teal,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _showReportFullscreen() {
    if (_report == null) return;
    final md = _report!.toMarkdown();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161922),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Row(
              children: [
                Icon(Icons.description, color: Colors.tealAccent, size: 20),
                SizedBox(width: 8),
                Text('全车开放数据报告 (Markdown)',
                    style: TextStyle(color: Colors.white, fontSize: 15)),
              ],
            ),
            IconButton(
              icon: const Icon(Icons.copy, color: Colors.tealAccent, size: 18),
              tooltip: '一键复制',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: md));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制到剪贴板')),
                );
              },
            ),
          ],
        ),
        content: SizedBox(
          width: 700,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              md,
              style: const TextStyle(
                color: Colors.white70,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final supportedCount = _discoveredItems.where((i) => i.isSupported).length;
    final testedCount = _discoveredItems.length;

    return AlertDialog(
      backgroundColor: const Color(0xFF141720),
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      titlePadding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      actionsPadding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.tealAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(Icons.manage_search,
                    color: Colors.tealAccent, size: 20),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '全车数据一键深度扫描与导出 (Deep Scan)',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '自动遍历标准 OBD、车辆标识、丰田混动 0x7E2 与发动机 0x7E0 专有数据块',
                    style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 9.5),
                  ),
                ],
              ),
            ],
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.close, color: Colors.white60, size: 20),
            onPressed: _isScanning ? null : () => Navigator.pop(context),
          ),
        ],
      ),
      content: SizedBox(
        width: 760,
        height: 275,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. 进度条与状态条
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1B202C),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          _statusMessage,
                          style: const TextStyle(
                              color: Colors.tealAccent, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '开放 $supportedCount / 已测 $testedCount 项',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: _progress.clamp(0.0, 1.0),
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(Colors.tealAccent),
                    minHeight: 5,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),

            // 2. 活跃 ECU 芯片指示栏
            if (_activeEcus.isNotEmpty) ...[
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: _activeEcus.map((ecu) {
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blueAccent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: Colors.blueAccent.withValues(alpha: 0.4)),
                    ),
                    child: Text(
                      ecu,
                      style: const TextStyle(
                          color: Colors.lightBlueAccent, fontSize: 9.5),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 6),
            ],

            // 3. 实时探测列表
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: _discoveredItems.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.radar,
                                size: 36, color: Colors.white.withValues(alpha: 0.2)),
                            const SizedBox(height: 8),
                            const Text(
                              '点击下方【开始深度扫描】，适配器将依次向全车 ECU 发起只读探测\n测算您的 Yaris Z 混动开放的所有数据项与采样报文',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 11.5),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _listScrollController,
                        itemCount: _discoveredItems.length,
                        itemBuilder: (ctx, i) {
                          final item = _discoveredItems[i];
                          final isSupp = item.isSupported;

                          Color catColor;
                          if (item.category.contains('混动')) {
                            catColor = Colors.tealAccent;
                          } else if (item.category.contains('ECM')) {
                            catColor = Colors.orangeAccent;
                          } else if (item.category.contains('车辆')) {
                            catColor = Colors.purpleAccent;
                          } else {
                            catColor = Colors.lightBlueAccent;
                          }

                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: const BoxDecoration(
                              border: Border(
                                  bottom: BorderSide(
                                      color: Colors.white10, width: 0.5)),
                            ),
                            child: Row(
                              children: [
                                // 分类标签
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 5, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: catColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(
                                        color: catColor.withValues(alpha: 0.4)),
                                  ),
                                  child: Text(
                                    item.category,
                                    style: TextStyle(
                                        color: catColor, fontSize: 9.5),
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // 指令与寻址
                                Text(
                                  '[${item.header}] ${item.command}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 11,
                                  ),
                                ),
                                const SizedBox(width: 8),

                                // 传感器名称
                                Expanded(
                                  child: Text(
                                    item.name,
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 11),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),

                                // 采样值或应答
                                if (item.decodedHint != null)
                                  Container(
                                    margin: const EdgeInsets.only(right: 8),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 5, vertical: 1.5),
                                    decoration: BoxDecoration(
                                      color: Colors.greenAccent
                                          .withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      item.decodedHint!,
                                      style: const TextStyle(
                                          color: Colors.greenAccent,
                                          fontSize: 10),
                                    ),
                                  ),

                                // 状态指示 (开放/未开放)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isSupp
                                        ? Colors.green.withValues(alpha: 0.2)
                                        : Colors.grey.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(
                                        color: isSupp
                                            ? Colors.greenAccent
                                            : Colors.white24),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        isSupp
                                            ? Icons.check_circle
                                            : Icons.cancel_outlined,
                                        size: 11,
                                        color: isSupp
                                            ? Colors.greenAccent
                                            : Colors.white38,
                                      ),
                                      const SizedBox(width: 3),
                                      Text(
                                        isSupp ? '开放' : '无数据',
                                        style: TextStyle(
                                          color: isSupp
                                              ? Colors.greenAccent
                                              : Colors.white38,
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_report != null) ...[
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E3A2F),
              foregroundColor: Colors.tealAccent,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: const BorderSide(color: Colors.tealAccent),
              ),
            ),
            icon: const Icon(Icons.copy, size: 15),
            label: const Text('复制 Markdown 报告',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
            onPressed: _copyMarkdownReport,
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF222C3D),
              foregroundColor: Colors.lightBlueAccent,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
                side: const BorderSide(color: Colors.lightBlueAccent),
              ),
            ),
            icon: const Icon(Icons.visibility, size: 15),
            label: const Text('查看报告全文',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
            onPressed: _showReportFullscreen,
          ),
        ],
        const SizedBox(width: 6),
        if (_isScanning)
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade900,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            ),
            icon: const Icon(Icons.stop, size: 15),
            label: const Text('中止扫描', style: TextStyle(fontSize: 11.5)),
            onPressed: _cancelScan,
          )
        else
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            ),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: Text(_report == null ? '开始深度扫描' : '重新扫描',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.bold)),
            onPressed: _startScan,
          ),
        TextButton(
          onPressed: _isScanning ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
