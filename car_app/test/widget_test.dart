import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/main.dart';
import 'package:my_yaris/services/car_music_sync_service.dart';
import 'package:my_yaris/services/task_poller_service.dart';
import 'mock_storage_service.dart';

void main() {
  testWidgets('MyYarisApp redesigned 4-tab shell smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final mockStorage = MockStorageService();
    final poller = TaskPollerService(storage: mockStorage);

    addTearDown(() {
      poller.stop();
      CarMusicSyncService().stop();
    });

    await tester.pumpWidget(MyYarisApp(storage: mockStorage, poller: poller));

    // Verify root widget and 4 navigation rail items
    expect(find.byType(MyYarisApp), findsOneWidget);
    expect(find.text('首页'), findsOneWidget);
    expect(find.text('音乐'), findsOneWidget);
    expect(find.text('车况'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    // Home dashboard cards
    expect(find.text('手机导航接收'), findsOneWidget);
    expect(find.text('打开 NAVITIME'), findsOneWidget);
    expect(find.text('正在播放'), findsOneWidget);
    expect(find.text('—'), findsAtLeastNWidgets(4));

    // Debug entries must not be exposed
    expect(find.textContaining('连接与调试'), findsNothing);
    expect(find.textContaining('长轮询'), findsNothing);
    expect(find.textContaining('实时活动与回执日志'), findsNothing);
    expect(find.textContaining('全车深度扫描'), findsNothing);

    // Switch to OBD tab
    await tester.tap(find.text('车况'));
    await tester.pumpAndSettle();
    expect(find.text('混动与车辆状态'), findsOneWidget);
    expect(find.text('连接蓝牙 OBD'), findsOneWidget);

    // Switch to Settings tab
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('后端服务连接'), findsOneWidget);
    expect(find.text('接收手机导航'), findsOneWidget);
    expect(find.text('全屏沉浸显示'), findsOneWidget);

    poller.stop();
    CarMusicSyncService().stop();
  });
}
