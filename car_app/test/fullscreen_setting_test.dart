import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/car_music_sync_service.dart';
import 'package:my_yaris/services/system_ui_service.dart';
import 'package:my_yaris/services/task_poller_service.dart';
import 'package:my_yaris/ui/connection_debug_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:my_yaris/services/storage_service.dart';
import 'mock_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Fullscreen Settings & SystemUiService Tests', () {
    test('MockStorageService default isFullscreenEnabled is true', () {
      final storage = MockStorageService();
      expect(storage.isFullscreenEnabled, isTrue);
      storage.setFullscreenEnabled(false);
      expect(storage.isFullscreenEnabled, isFalse);
      storage.setFullscreenEnabled(true);
      expect(storage.isFullscreenEnabled, isTrue);
    });

    test('SharedPreferencesStorageService defaults to true when key absent', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = await SharedPreferencesStorageService.create();
      expect(storage.isFullscreenEnabled, isTrue);

      await storage.setFullscreenEnabled(false);
      expect(storage.isFullscreenEnabled, isFalse);

      await storage.setFullscreenEnabled(true);
      expect(storage.isFullscreenEnabled, isTrue);
    });

    test('SystemUiService.setFullscreen executes without throwing', () async {
      // Setup mock method call handler
      const channel = MethodChannel('com.myyaris.my_yaris/system_ui');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return true;
      });

      await SystemUiService.setFullscreen(true);
      expect(calls.isNotEmpty, isTrue);
      expect(calls.last.method, 'setFullscreen');
      expect(calls.last.arguments, {'enabled': true});

      await SystemUiService.setFullscreen(false);
      expect(calls.last.method, 'setFullscreen');
      expect(calls.last.arguments, {'enabled': false});

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    testWidgets('ConnectionDebugPage renders fullscreen button and toggles state', (WidgetTester tester) async {
      final mockStorage = MockStorageService();
      final poller = TaskPollerService(storage: mockStorage);

      addTearDown(() {
        poller.stop();
        CarMusicSyncService().stop();
      });

      await tester.pumpWidget(MaterialApp(
        home: ConnectionDebugPage(storage: mockStorage, poller: poller),
      ));

      // Check AppBar fullscreen icon button exists (default fullscreen -> tooltip '退出全屏')
      expect(find.byTooltip('退出全屏'), findsOneWidget);

      // Tap fullscreen icon to toggle OFF
      await tester.tap(find.byTooltip('退出全屏'));
      await tester.pumpAndSettle();

      expect(mockStorage.isFullscreenEnabled, isFalse);
      expect(find.byTooltip('全屏显示'), findsOneWidget);

      // Open settings dialog
      await tester.tap(find.byTooltip('连接参数配置'));
      await tester.pumpAndSettle();

      expect(find.text('全屏显示 (沉浸模式)'), findsOneWidget);
      expect(find.text('已关闭：恢复系统标准状态栏显示'), findsOneWidget);

      // Toggle switch in dialog
      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(mockStorage.isFullscreenEnabled, isTrue);
      expect(find.text('已开启：隐藏系统状态栏，屏幕手势可临时呼出'), findsOneWidget);
    });
  });
}
