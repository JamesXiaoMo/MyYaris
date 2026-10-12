// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/main.dart';
import 'package:my_yaris/services/task_poller_service.dart';
import 'mock_storage_service.dart';

void main() {
  testWidgets('MyYarisApp smoke test', (WidgetTester tester) async {
    final mockStorage = MockStorageService();
    final poller = TaskPollerService(storage: mockStorage);

    // Build our app and trigger a frame.
    await tester.pumpWidget(MyYarisApp(storage: mockStorage, poller: poller));

    // Verify root widget exists and title is rendered
    expect(find.byType(MyYarisApp), findsOneWidget);
    expect(find.text('MyYaris 车机助手'), findsOneWidget);
    expect(find.text('连接与调试 (后台与导航)'), findsOneWidget);
    expect(find.text('当前播放信息与播控'), findsOneWidget);

    // Tap to enter secondary debug & connection page
    await tester.tap(find.text('连接与调试 (后台与导航)'));
    await tester.pumpAndSettle();

    // Verify secondary page contains connection poller controls
    expect(find.text('启用轮询'), findsOneWidget);
  });
}
